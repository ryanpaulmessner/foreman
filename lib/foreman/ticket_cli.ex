defmodule Foreman.TicketCLI do
  @moduledoc "Offline ticket commands. All writes are validated before publication."
  alias Foreman.{TicketFile, TicketStore}
  @verbs ~w(new show ls ready update close reopen dep note tree renumber check)
  @switches [
    json: :boolean,
    title: :string,
    type: :string,
    status: :string,
    priority: :integer,
    parent: :string,
    blocked_by: :string,
    related: :string,
    supersedes: :string,
    discovered_from: :string,
    labels: :string,
    body: :string,
    reason: :string,
    actor: :string
  ]
  @status_atoms %{
    "open" => :open,
    "in_progress" => :in_progress,
    "closed" => :closed,
    "deferred" => :deferred,
    "parked" => :parked
  }
  @status_events %{
    "open" => :reopen,
    "in_progress" => :start,
    "closed" => :close,
    "deferred" => :defer,
    "parked" => :park
  }

  def command?(args, opts \\ []) do
    verb = Enum.find(args, &(not String.starts_with?(&1, "--")))

    overlay_read? =
      verb in ~w(show ls) and Enum.any?(~w(--overlay --stage --project --repo), &(&1 in args))

    verb in @verbs and not overlay_read? and
      (verb not in ~w(show ls) or local_tickets?(opts[:cwd] || File.cwd!()))
  end

  def run(args, options \\ []) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    result =
      with true <- invalid == [],
           :ok <- valid_options(positional, opts),
           {:ok, root} <- root(options[:cwd] || File.cwd!()) do
        execute(positional, opts, root)
      else
        false -> {:error, "invalid options: #{inspect(invalid)}"}
        error -> error
      end

    {code, output} =
      case result do
        {:ok, output} -> {0, output}
        {:invalid, output} -> {2, output}
        {:error, {kind, reason}} when kind in [:busy, :io] -> {0, %{"warning" => reason}}
        {:error, reason} -> {2, %{"error" => reason}}
      end

    if "--json" in args, do: IO.puts(Jason.encode!(output)), else: IO.puts(human(output))
    code
  rescue
    error in [File.Error, File.CopyError] ->
      output = %{"warning" => "ticket filesystem unavailable: #{Exception.message(error)}"}
      if "--json" in args, do: IO.puts(Jason.encode!(output)), else: IO.puts(human(output))
      0
  end

  defp execute(["check"], _opts, root) do
    errors = TicketStore.check(root)
    result = %{"valid" => errors == [], "errors" => errors}
    if errors == [], do: {:ok, result}, else: {:invalid, result}
  end

  defp execute(args, opts, root) do
    with {:ok, tickets} <- TicketStore.load(root) do
      command(args, opts, root, tickets)
    end
  end

  defp command(["new" | title], opts, root, tickets) when length(title) <= 1 do
    title = opts[:title] || List.first(title)
    parent = nullable(opts[:parent])

    with {:ok, prefix} <- prefix(root),
         true <- is_nil(parent) or Map.has_key?(tickets, parent),
         true <- is_binary(title) and String.trim(title) != "" do
      id = TicketStore.next_id(prefix, parent, Map.keys(tickets))

      facts = %{
        "id" => id,
        "title" => title,
        "type" => "task",
        "status" => "open",
        "priority" => 2,
        "parent" => parent,
        "blocked_by" => [],
        "related" => [],
        "supersedes" => [],
        "discovered_from" => nil,
        "labels" => [],
        "created" => today(),
        "closed" => nil,
        "close_reason" => nil
      }

      ticket = apply_options(%{facts: facts, body: ""}, opts)
      save(root, tickets, Map.put(tickets, id, ticket), id)
    else
      false -> {:error, "new requires a title and an existing parent (if supplied)"}
      error -> error
    end
  end

  defp command(["show", id], _, _, tickets), do: fetch(tickets, id, &{:ok, output(&1)})

  defp command([verb], opts, _, tickets) when verb in ~w(ls ready) do
    rows =
      tickets
      |> Map.values()
      |> Enum.filter(fn ticket ->
        facts = ticket.facts

        (is_nil(opts[:status]) or facts["status"] == opts[:status]) and
          (is_nil(opts[:type]) or facts["type"] == opts[:type]) and
          (verb != "ready" or
             (facts["status"] == "open" and facts["type"] != "epic" and
                Enum.all?(
                  facts["blocked_by"],
                  &(get_in(tickets, [&1, :facts, "status"]) == "closed")
                )))
      end)
      |> Enum.sort_by(&order(verb, &1.facts))
      |> Enum.map(&output/1)

    {:ok, rows}
  end

  defp command(["tree"], _, _, tickets), do: {:ok, tree(tickets, nil, MapSet.new())}

  defp command(["tree", id], _, _, tickets),
    do:
      fetch(tickets, id, fn ticket ->
        {:ok, Map.put(output(ticket), "children", tree(tickets, id, MapSet.new([id])))}
      end)

  defp command(["update", id], opts, root, tickets) do
    fetch(tickets, id, fn ticket ->
      save(root, tickets, Map.put(tickets, id, apply_options(ticket, opts)), id)
    end)
  end

  defp command(["close", id], opts, root, tickets) do
    if is_binary(opts[:reason]) and String.trim(opts[:reason]) != "" do
      fetch(tickets, id, fn ticket ->
        updated =
          ticket |> set_status("closed") |> put_in([:facts, "close_reason"], opts[:reason])

        save(root, tickets, Map.put(tickets, id, updated), id)
      end)
    else
      {:error, "close requires --reason"}
    end
  end

  defp command(["reopen", id], _, root, tickets) do
    fetch(tickets, id, fn ticket ->
      save(root, tickets, Map.put(tickets, id, set_status(ticket, "open")), id)
    end)
  end

  defp command(["dep", operation, id, blocker], _, root, tickets) when operation in ~w(add rm) do
    fetch(tickets, id, fn ticket ->
      refs = ticket.facts["blocked_by"]

      refs =
        if operation == "add", do: Enum.uniq([blocker | refs]), else: List.delete(refs, blocker)

      updated = put_in(ticket, [:facts, "blocked_by"], refs)
      save(root, tickets, Map.put(tickets, id, updated), id)
    end)
  end

  defp command(["note", id, text], opts, root, tickets) do
    fetch(tickets, id, fn ticket ->
      actor = opts[:actor] || System.get_env("FOREMAN_ACTOR", "user")
      line = "- #{today()} #{actor}: #{text}\n"
      body = append_note(ticket.body, line)
      save(root, tickets, Map.put(tickets, id, %{ticket | body: body}), id)
    end)
  end

  defp command(["renumber", old, new], _, root, tickets) do
    cond do
      not TicketFile.valid_id?(new) ->
        {:error, "invalid new id"}

      Map.has_key?(tickets, new) ->
        {:error, "new id already exists"}

      not Map.has_key?(tickets, old) ->
        {:error, "unknown ticket: #{old}"}

      true ->
        updated =
          Map.new(tickets, fn {id, ticket} ->
            facts =
              Map.new(ticket.facts, fn {key, value} ->
                value =
                  cond do
                    key in ~w(id parent discovered_from) and value == old ->
                      new

                    key in ~w(blocked_by related supersedes) ->
                      Enum.map(value, &if(&1 == old, do: new, else: &1))

                    true ->
                      value
                  end

                {key, value}
              end)

            body =
              Regex.replace(
                ~r/(?<![a-zA-Z0-9_.-])#{Regex.escape(old)}(?![a-zA-Z0-9_-]|\.[0-9])(?=\.md\b|\.(?:\s|$)|[^.]|$)/,
                ticket.body,
                fn _ -> new end
              )

            {if(id == old, do: new, else: id), %{ticket | facts: facts, body: body}}
          end)

        save(root, tickets, updated, new)
    end
  end

  defp command(_, _, _, _),
    do:
      {:error,
       "usage: foreman new|show|ls|ready|update|close|reopen|dep|note|tree|renumber|check [arguments]"}

  defp order("ready", facts),
    do:
      {Foreman.Priority.rank(facts["priority"]), is_nil(facts["created"]), facts["created"],
       facts["id"]}

  defp order(_, facts), do: facts["id"]

  defp save(root, before, tickets, id) do
    with :ok <- TicketStore.save(root, before, tickets), do: {:ok, output(tickets[id])}
  end

  defp fetch(tickets, id, fun) do
    case Map.fetch(tickets, id) do
      {:ok, ticket} -> fun.(ticket)
      :error -> {:error, "unknown ticket: #{id}"}
    end
  end

  defp apply_options(ticket, opts) do
    ticket =
      Enum.reduce(opts, ticket, fn {key, value}, ticket ->
        field = to_string(key)

        cond do
          field in ~w(blocked_by related supersedes labels) ->
            put_in(ticket, [:facts, field], csv(value))

          field in ~w(parent discovered_from) ->
            put_in(ticket, [:facts, field], nullable(value))

          field in ~w(title type priority) ->
            put_in(ticket, [:facts, field], value)

          field == "body" ->
            %{ticket | body: value}

          true ->
            ticket
        end
      end)

    ticket = if opts[:status], do: set_status(ticket, opts[:status]), else: ticket

    if opts[:status] == "parked",
      do: put_in(ticket, [:facts, "parked_reason"], opts[:reason]),
      else: ticket
  end

  defp set_status(ticket, status) do
    if Map.has_key?(@status_atoms, status) do
      {next, []} =
        Foreman.TicketStatusMachine.step(
          @status_atoms[ticket.facts["status"]],
          @status_events[status],
          nil
        )

      facts =
        ticket.facts
        |> Map.put("status", to_string(next))
        |> Map.put("parked", if(next == :parked, do: ticket.facts["parked"] || today()))
        |> Map.put("parked_reason", if(next == :parked, do: ticket.facts["parked_reason"]))
        |> Map.put("closed", if(next == :closed, do: ticket.facts["closed"] || today()))
        |> Map.put("close_reason", if(next == :closed, do: ticket.facts["close_reason"]))

      %{ticket | facts: facts}
    else
      put_in(ticket, [:facts, "status"], status)
    end
  end

  defp append_note(body, line) do
    case Regex.run(~r/^## Notes[ \t]*\r?$/m, body, return: :index) do
      [{start, length}] ->
        position = start + length
        rest = binary_part(body, position, byte_size(body) - position)

        next =
          case Regex.run(~r/^## /m, rest, return: :index) do
            [{index, _}] -> position + index
            nil -> byte_size(body)
          end

        String.trim_trailing(binary_part(body, 0, next), "\n") <>
          "\n" <>
          line <>
          if(next < byte_size(body),
            do: "\n" <> binary_part(body, next, byte_size(body) - next),
            else: ""
          )

      nil ->
        String.trim_trailing(body, "\n") <>
          if(body == "", do: "", else: "\n\n") <> "## Notes\n" <> line
    end
  end

  defp tree(tickets, parent, seen) do
    tickets
    |> Map.values()
    |> Enum.filter(&(&1.facts["parent"] == parent and not MapSet.member?(seen, &1.facts["id"])))
    |> Enum.sort_by(& &1.facts["id"])
    |> Enum.map(fn ticket ->
      Map.put(
        output(ticket),
        "children",
        tree(tickets, ticket.facts["id"], MapSet.put(seen, ticket.facts["id"]))
      )
    end)
  end

  defp output(ticket) do
    ticket.facts
    |> Map.put("body", ticket.body)
    |> Map.update!("blocked_by", &Enum.sort/1)
    |> Map.update!("related", &Enum.sort/1)
    |> Map.update!("supersedes", &Enum.sort/1)
    |> Map.update!("labels", &Enum.sort/1)
  end

  defp root(cwd) do
    case System.cmd("git", ["-C", cwd, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {path, 0} -> {:ok, String.trim(path)}
      _ -> {:error, "run foreman ticket commands inside a git checkout"}
    end
  end

  defp local_tickets?(cwd) do
    case root(cwd) do
      {:ok, root} -> File.dir?(Path.join(root, "tickets")) or match?({:ok, _}, prefix(root))
      _ -> false
    end
  end

  defp prefix(root) do
    directory = System.get_env("FOREMAN_CONFIG_DIR", Path.expand("~/.config/foreman"))

    with {:ok, config} <- Foreman.Config.load(directory),
         [repo] <- Enum.filter(config["repos"], &(&1["path"] == root)),
         prefix when is_binary(prefix) <- repo["prefix"],
         true <- Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, prefix) do
      {:ok, prefix}
    else
      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error,
         "foreman.toml must contain one repo entry matching this checkout with a valid prefix"}
    end
  end

  defp valid_options([verb | _], opts) do
    fields = [
      :title,
      :type,
      :status,
      :priority,
      :parent,
      :blocked_by,
      :related,
      :supersedes,
      :discovered_from,
      :labels,
      :body
    ]

    allowed =
      [:json] ++
        case verb do
          "new" -> fields
          "update" -> if(opts[:status] == "parked", do: [:reason | fields], else: fields)
          "close" -> [:reason]
          "note" -> [:actor]
          "ls" -> [:status, :type]
          "ready" -> [:status, :type]
          _ -> []
        end

    case Keyword.keys(opts) -- allowed do
      [] -> :ok
      invalid -> {:error, "invalid options for #{verb}: #{inspect(invalid)}"}
    end
  end

  defp valid_options(_, _), do: {:error, "missing command"}

  defp csv(value),
    do:
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.uniq()
      |> Enum.sort()

  defp nullable(value) when value in [nil, "", "null"], do: nil
  defp nullable(value), do: value
  defp today, do: Date.utc_today() |> Date.to_iso8601()
  defp human(%{"error" => reason}), do: "error: " <> reason
  defp human(%{"warning" => reason}), do: "warning: " <> reason
  defp human(%{"valid" => true}), do: "tickets valid"
  defp human(%{"errors" => errors}), do: Enum.map_join(errors, "\n", &"#{&1.file}: #{&1.reason}")
  defp human(output), do: Jason.encode!(output, pretty: true)
end
