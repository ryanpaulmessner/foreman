defmodule Foreman.DocCLI do
  @moduledoc """
  `foreman doc path`: prints where a document goes, in the main checkout of the ticket's
  repo (docs/specs/doc-layout.md, decisions 3 and 4). Offline; prints paths and creates
  nothing. Plain output is the path alone, so scripts can use `$(foreman doc path ...)`;
  errors go to stderr (or `{"error": ...}` with `--json`) with exit 2.
  """
  alias Foreman.DocLayout
  alias Foreman.Requests.LocalRefs

  @usage "usage: foreman doc path <kind> <ticket-id> [--next] | foreman doc path note <kind> <slug>"

  def run(args, opts \\ []) do
    {flags, positional, invalid} =
      OptionParser.parse(args, strict: [next: :boolean, json: :boolean])

    result =
      try do
        case {invalid, positional, flags[:next]} do
          {[], ["path", "note", kind, slug], nil} -> note(kind, slug, opts)
          {[], ["path", kind, id], _} when kind != "note" -> ticket(kind, id, flags[:next])
          _ -> {:error, "#{@usage}; ticket kinds: #{Enum.join(DocLayout.ticket_kinds(), ", ")}"}
        end
      rescue
        # Never fall through to Foreman.CLI's exit-0 warning: scripts capture stdout as a path.
        error -> {:error, "doc path failed: " <> Exception.message(error)}
      end

    output(result, "--json" in args)
  end

  defp output(result, json?) do
    case result do
      {:ok, path} ->
        IO.puts(if json?, do: Jason.encode!(%{path: path}), else: path)
        0

      {:error, message} ->
        if json?,
          do: IO.puts(Jason.encode!(%{error: message})),
          else: IO.puts(:stderr, "error: " <> message)

        2
    end
  end

  defp ticket(kind, id, next?) do
    with {:ok, _} <- DocLayout.ticket_path(kind, id),
         {:ok, repos} <- repos(),
         {:ok, root} <- repo_for_ticket(id, repos),
         {:ok, relative} <- ticket_relative(root, kind, id, next?) do
      {:ok, Path.join(root, relative)}
    end
  end

  defp ticket_relative(root, kind, id, true), do: DocLayout.next_ticket_path(root, kind, id)
  defp ticket_relative(_root, kind, id, _), do: DocLayout.ticket_path(kind, id)

  defp note(kind, slug, opts) do
    today =
      Keyword.get_lazy(opts, :today, fn ->
        NaiveDateTime.local_now() |> NaiveDateTime.to_date()
      end)

    with {:ok, relative} <- DocLayout.note_path(kind, slug, today),
         {:ok, repos} <- repos(),
         {:ok, root} <- repo_for_cwd(opts[:cwd] || File.cwd!(), repos) do
      {:ok, Path.join(root, relative)}
    end
  end

  defp repos do
    directory = System.get_env("FOREMAN_CONFIG_DIR", Path.expand("~/.config/foreman"))

    with {:ok, config} <- Foreman.Config.load(directory), do: {:ok, config["repos"]}
  end

  # The prefix picks the repo; an unknown prefix never falls back to the cwd.
  defp repo_for_ticket(id, repos) do
    [prefix | _] = String.split(id, "-", parts: 2)

    case Enum.filter(repos, &(&1["prefix"] == prefix)) do
      [repo] ->
        {:ok, repo["path"]}

      [] ->
        known = repos |> Enum.map(& &1["prefix"]) |> Enum.filter(&is_binary/1) |> Enum.sort()

        {:error,
         "no registered repo has ticket prefix #{inspect(prefix)}; registered prefixes: " <>
           Enum.join(known, ", ")}

      matches ->
        {:error,
         "ticket prefix #{inspect(prefix)} is registered by several repos: " <>
           Enum.map_join(matches, ", ", & &1["key"])}
    end
  end

  # The nearest enclosing checkout (a worktree counts as its repo) matched against each
  # repo's path and code_path by git common directory.
  defp repo_for_cwd(cwd, repos) do
    with {:ok, checkout} <- enclosing_checkout(Path.expand(cwd)),
         {:ok, identity, _} <- LocalRefs.common_dir(checkout),
         %{} = repo <-
           Enum.find(repos, fn repo ->
             Enum.any?([repo["path"], repo["code_path"]], fn path ->
               is_binary(path) and match?({:ok, ^identity, _}, LocalRefs.common_dir(path))
             end)
           end) do
      {:ok, repo["path"]}
    else
      _ ->
        {:error, "#{cwd} is not in a registered repo (foreman.toml [[repos]] path or code_path)"}
    end
  end

  defp enclosing_checkout(dir) do
    cond do
      File.exists?(Path.join(dir, ".git")) -> {:ok, dir}
      Path.dirname(dir) == dir -> :error
      true -> enclosing_checkout(Path.dirname(dir))
    end
  end
end
