defmodule Foreman.AgentCommands do
  @moduledoc "Stable command envelope and transactional idempotency for HTTP/replay races."
  import Ecto.Query
  alias Foreman.{Agent, AgentCatalog, Overlay, Repo}

  def execute(request) do
    if request["action"] in ["show", "ls", "wait"], do: command(request), else: write(request)
  end

  defp write(%{"request_id" => id} = request) do
    case Ecto.UUID.dump(id) do
      {:ok, uuid} ->
        result =
          Repo.transaction(
            fn ->
              Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
                "foreman:request:" <> id
              ])

              case Repo.one(
                     from r in "agent_receipts",
                       where: r.request_id == ^uuid,
                       select: %{request: r.request, status: r.status, body: r.body}
                   ) do
                nil ->
                  {status, body} = command(request)

                  if request["action"] == "coordinator" and status != 200,
                    do: Repo.rollback({status, body})

                  if status not in [404, 503] do
                    Repo.insert_all("agent_receipts", [
                      %{request_id: uuid, request: request, status: status, body: body}
                    ])
                  end

                  {status, body}

                %{request: ^request, status: status, body: body} ->
                  {status, body}

                _ ->
                  {422, %{error: "request_id_reused"}}
              end
            end,
            timeout: 35_000
          )

        case result do
          {:ok, response} -> response
          {:error, {status, body}} -> {status, body}
        end

      _ ->
        {422, %{error: "invalid_request_id"}}
    end
  end

  defp write(request), do: write(Map.put(request, "request_id", Ecto.UUID.generate()))

  defp command(%{"action" => "coordinator"} = request) do
    case Foreman.Sessions.coordinator_command(request) do
      {:ok, body} -> {200, body}
      {:error, reason} -> {422, %{error: reason}}
    end
  end

  defp command(%{"action" => "wait", "id" => id}) do
    case Foreman.Requests.get(id) do
      nil -> {404, %{error: "not_found"}}
      request -> {200, request |> Jason.encode!() |> Jason.decode!()}
    end
  end

  defp command(%{"action" => "ls"} = request) do
    rows =
      for table <- ["tickets", "epics"],
          row <-
            Repo.all(from r in table, select: %{repo: r.repo_key, id: r.bead_id, stage: r.stage}),
          is_nil(request["project"]) or row.repo == request["project"],
          is_nil(request["stage"]) or row.stage == request["stage"],
          do: row

    in_scope = &(is_nil(request["project"]) or &1.repo == request["project"])

    {200,
     %{
       jumps: Enum.filter(Foreman.Priority.pending_jumps(), in_scope),
       priority_overrides: Enum.filter(Foreman.Priority.overrides(), in_scope),
       items: Enum.sort_by(rows, &{&1.repo, Foreman.Beads.Id.sort_key(&1.id)})
     }}
  end

  defp command(%{"project" => "__foreman__", "id" => "coordinator", "action" => action} = request)
       when action in ["ask", "session_resumed", "session_activity"] do
    key = Foreman.Sessions.coordinator_key()

    result =
      case action do
        "ask" ->
          if request["request_kind"] == "session_waiting",
            do: Foreman.SessionWaiting.ask(key, request),
            else: {:error, :invalid_command}

        _ ->
          event = if action == "session_activity", do: :activity, else: :resumed
          Foreman.Sessions.signal(key, request["session"], event, request["resume_tool"])
      end

    case result do
      {:ok, %Foreman.Requests.Request{} = ask} -> {200, %{id: ask.id, state: ask.state}}
      {:ok, session} -> {200, %{state: session.state}}
      {:error, reason} -> {422, %{error: reason}}
    end
  end

  defp command(request) do
    catalog = AgentCatalog.list()

    key =
      if is_binary(request["repo"]) and is_binary(request["id"]),
        do: {:ok, {request["repo"], request["id"]}},
        else: AgentCatalog.resolve(request, catalog)

    with {:ok, {repo, id} = key} <- key do
      case request["action"] do
        "ask" ->
          Agent.ensure_entity(key)

          case Foreman.Requests.ask(key, request["request_kind"], request) do
            {:ok, %Foreman.PlanningSession{} = session} -> {200, %{state: session.state}}
            {:ok, ask} -> {200, %{id: ask.id, state: ask.state}}
            {:error, :not_found} -> {404, %{error: "not_found"}}
            {:error, reason} -> {422, %{error: reason}}
          end

        action when action in ["session_resumed", "session_activity"] ->
          event = if action == "session_activity", do: :activity, else: :resumed

          case Foreman.Sessions.signal(key, request["session"], event, request["resume_tool"]) do
            {:ok, session} -> {200, %{state: session.state}}
            {:error, reason} -> {422, %{error: reason}}
          end

        "event" ->
          Agent.event(repo, id, request)

        "show" ->
          case Agent.ensure_entity(key) do
            nil ->
              {404, %{error: "not_found"}}

            row ->
              {200,
               %{
                 repo: repo,
                 id: id,
                 stage: row.stage,
                 allowed: Overlay.allowed_events(key),
                 history: Overlay.history(key)
               }}
          end

        action when action in ["attach", "detach"] ->
          with {:ok, epic} <-
                 AgentCatalog.resolve(
                   %{
                     "id" => request["epic"],
                     "kind" => "epic",
                     "project" => request["epic_project"],
                     "cwd" => request["cwd"]
                   },
                   catalog
                 ) do
            Agent.link(key, epic, action)
          else
            {:error, :unknown_project} -> {404, %{error: :unknown_project}}
            {:error, reason} -> {422, %{error: reason}}
          end

        _ ->
          {422, %{error: "invalid_command"}}
      end
    else
      {:error, :unknown_project} -> {404, %{error: :unknown_project}}
      {:error, reason} -> {422, %{error: reason}}
    end
  end
end
