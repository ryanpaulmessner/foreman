defmodule Foreman.Config.Schema do
  @moduledoc false

  def validate(config, complete? \\ false) do
    schema = %{
      "board" =>
        {:table,
         %{
           "swimlanes" => {:one_of, ~w(project epic none)},
           "stale_session_after" => :duration,
           "terminal_app" => :app,
           "tmux_session" => :key,
           "os_notifications" => :boolean
         }},
      "merge_policy" => {:one_of, ~w(board human)},
      "views" =>
        {:nonempty_list,
         {:table,
          %{
            "key" => :key,
            "title" => :text,
            "statuses" => {:list, {:one_of, ~w(open in_progress blocked deferred parked closed)}},
            "stages" => {:list, :stage},
            "stale" => :boolean
          }}},
      "columns" =>
        {:list,
         {:table,
          %{
            "title" => :text,
            "stages" => {:nonempty_list, :stage},
            "collapsed" => :boolean
          }}},
      "repos" =>
        {:list,
         {:table,
          %{
            "key" => :key,
            "path" => :path,
            "code_path" => :path,
            "prefix" => :key,
            "tickets" => {:one_of, ~w(files beads)},
            "default_kind" => {:one_of, Foreman.TicketFile.kinds()},
            "github" => :github,
            "forge" => {:one_of, ~w(github none)},
            "merge_policy" => {:one_of, ~w(board human)},
            "merge_base" => :branch,
            "color" => :text,
            "enabled" => :boolean
          }}},
      "backfill" => {:table, %{"closed" => :stage, "default" => :stage}},
      "epics" =>
        {:values, {:table, %{"pin" => :boolean, "collapse" => :boolean, "color" => :text}}}
    }

    with :ok <- check(config, {:table, schema}, "config"),
         :ok <- unique(Map.get(config, "repos", []), "key", "repos"),
         :ok <- unique(Map.get(config, "views", []), "key", "views"),
         :ok <-
           each(Map.get(config, "views", []), fn view, index ->
             required(view, ~w(key title), "views[#{index}]")
           end),
         :ok <- required_repos(Map.get(config, "repos", []), complete?),
         :ok <- required_config(config, complete?),
         :ok <- human_merge(config, complete?) do
      :ok
    end
  end

  def unique(items, key, field) do
    values = Enum.map(items, &Map.get(&1, key)) |> Enum.reject(&is_nil/1)

    if length(values) == length(Enum.uniq(values)),
      do: :ok,
      else: {:error, "#{field}: duplicate #{key}"}
  end

  defp required_config(_, false), do: :ok

  defp required_config(config, true) do
    with :ok <- required(config, ~w(board columns views repos backfill epics), "config"),
         :ok <- required(config["board"], ~w(swimlanes stale_session_after), "board"),
         :ok <- required(config["backfill"], ~w(closed default), "backfill") do
      each(config["columns"], fn column, index ->
        required(column, ~w(title stages), "columns[#{index}]")
      end)
    end
  end

  # Cross-field rule on the merged layers only: a local layer may set the policy for a
  # repo whose forge is declared in the global file.
  defp human_merge(_, false), do: :ok

  defp human_merge(config, true) do
    each(config["repos"], fn repo, index ->
      forge = repo["forge"] || if(repo["github"], do: "github", else: "none")

      if Foreman.MergePolicy.human?(repo, config) and
           (forge != "github" or not is_binary(repo["github"])),
         do:
           {:error,
            "repos[#{index}] (#{repo["key"]}): merge_policy \"human\" requires forge = \"github\" and a github remote"},
         else: :ok
    end)
  end

  defp required_repos(repos, complete?) do
    keys = if complete?, do: ~w(key path), else: ~w(key)
    each(repos, fn repo, index -> required(repo, keys, "repos[#{index}]") end)
  end

  defp required(map, keys, field) do
    case Enum.find(keys, &(not Map.has_key?(map, &1))) do
      nil -> :ok
      key -> {:error, "#{field}.#{key}: required"}
    end
  end

  defp check(value, {:table, schema}, field) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, item}, :ok ->
      result =
        case Map.fetch(schema, key) do
          {:ok, type} -> check(item, type, "#{field}.#{key}")
          :error -> {:error, "#{field}.#{key}: unknown option"}
        end

      continue(result)
    end)
  end

  defp check(value, {:values, type}, field) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, item}, :ok ->
      continue(check(item, type, "#{field}.#{key}"))
    end)
  end

  defp check(value, {kind, type}, field)
       when kind in [:list, :nonempty_list] and is_list(value) do
    if kind == :nonempty_list and value == [] do
      {:error, "#{field}: must not be empty"}
    else
      each(value, fn item, index -> check(item, type, "#{field}[#{index}]") end)
    end
  end

  defp check(value, :stage, field) do
    stages = Enum.map(Foreman.Stage.__fsm__(:states), &Atom.to_string/1)

    if value in stages,
      do: :ok,
      else: {:error, "#{field}: unknown ticket stage #{inspect(value)}"}
  end

  defp check(value, {:one_of, options}, field) do
    if value in options,
      do: :ok,
      else: {:error, "#{field}: expected one of #{Enum.join(options, ", ")}"}
  end

  defp check(value, :boolean, _) when is_boolean(value), do: :ok
  defp check(value, :text, _) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp check(value, :key, field), do: pattern(value, ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/, field)
  defp check(value, :github, field), do: pattern(value, ~r/\A[^\/\s]+\/[^\/\s]+\z/, field)

  defp check(value, :app, field) do
    if Foreman.Terminal.app?(value), do: :ok, else: {:error, "#{field}: invalid value"}
  end

  defp check(value, :branch, field) do
    if Foreman.Requests.LocalRefs.branch_name?(value),
      do: :ok,
      else: {:error, "#{field}: invalid branch name"}
  end

  defp check(value, :duration, field), do: pattern(value, ~r/\A[1-9][0-9]*(s|m|h|d)\z/, field)

  defp check(value, :path, field) do
    pattern(value, ~r/\A(?:~\/|\/)[^\x00\r\n]+\z/, field)
  end

  defp check(_, _, field), do: {:error, "#{field}: invalid value or shape"}

  defp pattern(value, regex, field) do
    if is_binary(value) and Regex.match?(regex, value),
      do: :ok,
      else: {:error, "#{field}: invalid value"}
  end

  defp each(items, fun) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      continue(fun.(item, index))
    end)
  end

  defp continue(:ok), do: {:cont, :ok}
  defp continue(error), do: {:halt, error}
end
