defmodule Foreman.AgentSessions do
  @moduledoc """
  Session identity (spec Decisions 1-6): lookups by id, live name and live pane, the
  writers (registration, dispatch, board launch) and ask resolution.

  A row is live while `ended_at` is null; `Foreman.ExternalSession` decides the
  liveness step. A writer that claims a live name on another pane or server ends
  the older row first, so the partial unique index (Decision 2) holds.
  """
  import Ecto.Query
  alias Foreman.{AgentSession, ExternalSession, PlanningSession, Repo}

  @coordinators ~w(main_coordinator epic_coordinator)
  @main_name "coordinator"

  def get(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(AgentSession, uuid)
      :error -> nil
    end
  end

  def get(_), do: nil

  def live_by_name(name) when is_binary(name),
    do: Repo.one(from s in AgentSession, where: s.name == ^name and is_nil(s.ended_at))

  def live_by_name(_), do: nil

  @doc "The live row on `pane` of `server` (`\"board\"` or `\"default\"`); the newest when aliases share a pane."
  def live_by_pane(pane, server) when is_binary(pane) and is_binary(server) do
    Repo.one(
      from s in AgentSession,
        where:
          s.pane_id == ^pane and s.tmux_server in ^same_servers(server) and is_nil(s.ended_at),
        order_by: [desc: coalesce(s.last_seen_at, s.started_at), desc: s.started_at],
        limit: 1
    )
  end

  def live_by_pane(_, _), do: nil

  @doc "Inserts a live row. A second live row with the same name is refused by the index."
  def create(attrs) do
    attrs = Map.put_new(attrs, :started_at, now())
    %AgentSession{} |> AgentSession.changeset(attrs) |> Repo.insert()
  end

  @doc "Ends a live row; ended rows stay ended (a later claim of the name makes a new row)."
  def end_session(session, at \\ nil)

  def end_session(%AgentSession{ended_at: nil} = session, at) do
    {:ended, [save: :ended_at]} = ExternalSession.step(:running, :pane_gone, %{})
    session |> Ecto.Changeset.change(ended_at: at || now()) |> Repo.update!()
  end

  def end_session(session, _), do: session

  @doc "The live main coordinator, else the most recent one."
  def main_coordinator do
    Repo.one(
      from s in AgentSession,
        where: s.kind == "main_coordinator",
        order_by: [desc: is_nil(s.ended_at), desc: s.started_at],
        limit: 1
    )
  end

  @doc "Maps a `$TMUX` socket path to the tmux server it names, or nil for other servers."
  def server_for_socket(nil), do: "default"

  def server_for_socket(path) when is_binary(path) do
    case Path.basename(path) do
      "" -> "default"
      name -> socket_server(name)
    end
  end

  def server_for_socket(_), do: nil

  # The external socket wins: when the board and external sockets name one tmux server
  # (board.sh sets both to "default"), callers on it are "default", as registered rows are.
  defp socket_server(name) do
    cond do
      name == external_socket() -> "default"
      name == planning_socket() -> "board"
      true -> nil
    end
  end

  defp planning_socket, do: Application.get_env(:foreman, :planning_tmux_socket, "foreman")
  defp external_socket, do: Application.get_env(:foreman, :external_tmux_socket, "default")

  @doc """
  The server labels that name the same tmux server as `server`: both labels when the
  board and external sockets are one server, else `server` alone.
  """
  def same_servers(server) when server in ["board", "default"] do
    if planning_socket() == external_socket(), do: ["board", "default"], else: [server]
  end

  def same_servers(server), do: [server]

  defp same_server?(a, b), do: a in same_servers(b)

  @doc """
  Finds the session behind an ask (Decision 5): the row with that id (board hooks send the
  conversation UUID), the live row with that name, then the live row on the caller's pane. A name whose row
  sits on another pane of the caller's server does not match, so a build that inherited its
  coordinator's `FOREMAN_SESSION` never resolves to the coordinator.
  """
  def resolve_asker(params) do
    name = text(params["session"])
    pane = pane(params["tmux_pane"])
    server = if pane, do: server_for_socket(params["tmux_socket"])
    fits? = &(&1 && consistent?(&1, pane, server))

    # A UUID names exactly one session (board hooks send their conversation id), live or not.
    by_id = if name, do: get(name)
    by_name = live_by_name(name)

    cond do
      fits?.(by_id) -> {:ok, by_id}
      fits?.(by_name) -> {:ok, by_name}
      row = live_by_pane(pane, server) -> {:ok, row}
      true -> {:unknown, unknown_warning(params["session"], params["tmux_pane"])}
    end
  end

  def unknown_warning(name, pane),
    do:
      "The board does not know this session (name #{shown(name)}, pane #{shown(pane)}). " <>
        "The card shows that the source is unknown."

  defp shown(value), do: text(value) || "unset"

  defp consistent?(row, pane, server),
    do:
      is_nil(pane) or is_nil(server) or is_nil(row.pane_id) or
        (row.pane_id == pane and same_server?(row.tmux_server, server))

  @doc """
  The source row of a card asked before identity rows existed (D3): the session with its
  name (or id) that was live when it was asked. Cards asked since then keep the row fixed
  at ask time, or none.
  """
  def legacy(%{session: name} = request) when is_binary(name) do
    asked_at = Map.get(request, :inserted_at)

    if asked_at && DateTime.compare(asked_at, identity_since()) == :lt,
      do: at_ask_time(name, asked_at)
  end

  def legacy(_), do: nil

  @version 20_261_103_211_112

  # When this database got identity rows: the migration's own timestamp.
  defp identity_since do
    case :persistent_term.get({__MODULE__, :since}, nil) do
      nil ->
        case Repo.query!("SELECT inserted_at FROM schema_migrations WHERE version = $1", [
               @version
             ]).rows do
          [[at]] ->
            since = DateTime.from_naive!(at, "Etc/UTC")
            :persistent_term.put({__MODULE__, :since}, since)
            since

          _ ->
            now()
        end

      since ->
        since
    end
  end

  defp at_ask_time(name, asked_at) do
    ids =
      case Ecto.UUID.cast(name) do
        {:ok, id} -> [id]
        :error -> []
      end

    Repo.one(
      from s in AgentSession,
        where:
          (s.name == ^name or s.id in type(^ids, {:array, :binary_id})) and
            s.started_at <= ^asked_at and (is_nil(s.ended_at) or s.ended_at >= ^asked_at),
        order_by: [desc: s.started_at],
        limit: 1
    )
  end

  @doc """
  Registration (`foreman session register`): pi sessions are builds, Claude sessions are
  coordinators (`coordinator` is the main one). `parent` names the coordinator that
  started it. Callers hold the session-name lock.
  """
  def register(attrs) do
    name = attrs["name"]
    parent = parent_row(attrs["parent"], name)

    kind =
      cond do
        attrs["harness"] == "pi" -> "build"
        name == @main_name and is_nil(parent) -> "main_coordinator"
        true -> "epic_coordinator"
      end

    parent =
      cond do
        parent -> parent
        kind == "epic_coordinator" -> main_coordinator()
        true -> nil
      end

    claim(name, "default", attrs["pane"], %{
      kind: kind,
      harness: attrs["harness"],
      workdir: attrs["workdir"],
      parent_id: parent && parent.id
    })
  end

  @doc """
  Dispatch (`foreman dispatch`): the build's own row, by its name. A live coordinator with
  that name is never taken over; the dispatch then has no row. Callers hold the overlay lock.
  """
  def record_dispatch({repo, id}, payload) do
    name = payload["session"]
    lock(name)

    case live_by_name(name) do
      %AgentSession{kind: kind} when kind != "build" ->
        nil

      _ ->
        parent = parent_row(payload["coordinator"], name)
        # A pane on a tmux server the board does not read is not recorded.
        server = Map.get(payload, "tmux_server", "default")
        pane = if server, do: pane(payload["window"])

        claim(name, server || "default", pane, %{
          kind: "build",
          harness: payload["harness"],
          model: payload["model"],
          conversation_id: text(payload["pi_session"]),
          workdir: payload["workdir"],
          branch: payload["branch"],
          project: repo,
          ticket: id,
          parent_id: parent && parent.id
        })
    end
  end

  defp parent_row(name, own) do
    if text(name) && name != own do
      case live_by_name(name) do
        %AgentSession{kind: kind} = row when kind in @coordinators -> row
        _ -> nil
      end
    end
  end

  @doc "The live coordinator registered on a pane of the default server (dispatch's caller)."
  def coordinator_on_pane(pane, server \\ "default") do
    case live_by_pane(pane(pane), server) do
      %AgentSession{kind: kind} = row when kind in @coordinators -> row
      _ -> nil
    end
  end

  # Same live name on the same server and pane (or no pane yet) is the same session:
  # update it, keeping fields already known. Otherwise the older claim ends.
  defp claim(name, server, pane, fields) do
    now = now()

    live = live_by_name(name)

    case live && same_session?(live, server, pane) && live do
      %AgentSession{pane_id: current} = row ->
        changes =
          fields
          |> Enum.reject(fn {key, value} ->
            is_nil(value) or (key in [:project, :ticket] and Map.get(row, key))
          end)
          |> Map.new()
          |> Map.merge(%{last_seen_at: now, pane_id: pane || current})

        row |> AgentSession.changeset(changes) |> Repo.update!()

      _ ->
        if live, do: end_session(live, now)

        {:ok, row} =
          create(
            Map.merge(fields, %{
              name: name,
              tmux_server: server,
              pane_id: pane,
              started_at: now,
              last_seen_at: now
            })
          )

        row
    end
  end

  # Same live name on the same tmux server and pane (or no pane yet on either side).
  defp same_session?(%AgentSession{tmux_server: row_server, pane_id: current}, server, pane),
    do: same_server?(row_server, server) and (is_nil(current) or is_nil(pane) or current == pane)

  @doc """
  Board launch: the planning session's own row (same id, conversation id and transaction),
  live while the planning session is starting, running or waiting.
  """
  def sync_planning(%PlanningSession{} = planning, opts \\ []) do
    lock(planning.ticket)
    live? = planning.state in [:starting, :running, :waiting]
    row = Repo.get(AgentSession, planning.session_id)

    row =
      cond do
        is_nil(row) and live? ->
          other = live_by_name(planning.ticket)
          if other, do: end_session(other)
          {:ok, row} = create(planning_fields(planning, opts))
          row

        is_nil(row) ->
          {:ok, row} = create(Map.put(planning_fields(planning, opts), :ended_at, now()))
          row

        live? and row.ended_at ->
          # A resumed conversation keeps its row; the name is claimed again.
          other = live_by_name(row.name)
          if other && other.id != row.id, do: end_session(other)
          {:running, _} = ExternalSession.step(:ended, :register, %{})
          touch(row, %{ended_at: nil, pane_id: opts[:pane] || row.pane_id})

        not live? and is_nil(row.ended_at) ->
          end_session(row)

        true ->
          touch(row, if(opts[:pane], do: %{pane_id: opts[:pane]}, else: %{}))
      end

    if planning.agent_session_id != row.id do
      Repo.update_all(
        from(p in PlanningSession, where: p.session_id == ^planning.session_id),
        set: [agent_session_id: row.id]
      )
    end

    row
  end

  defp planning_fields(planning, opts) do
    main? = Foreman.Sessions.coordinator?(planning)
    parent = if main?, do: nil, else: main_coordinator()

    %{
      id: planning.session_id,
      name: planning.ticket,
      kind: if(main?, do: "main_coordinator", else: "epic_coordinator"),
      parent_id: parent && parent.id,
      harness: "claude",
      conversation_id: planning.session_id,
      tmux_server: "board",
      pane_id: opts[:pane],
      project: if(main?, do: nil, else: planning.project),
      ticket: if(main?, do: nil, else: planning.ticket),
      workdir: planning.workdir,
      started_at: now(),
      last_seen_at: now()
    }
  end

  defp touch(row, changes),
    do: row |> AgentSession.changeset(Map.put(changes, :last_seen_at, now())) |> Repo.update!()

  @doc """
  Rows read before a pane listing, for `end_missing/2`. Only default-server rows (and builds
  stored as "board" when both sockets are one server): board rows follow their planning session.
  """
  def live_default do
    Repo.all(
      from s in AgentSession,
        where:
          is_nil(s.ended_at) and
            (s.tmux_server == "default" or
               (s.tmux_server in ^same_servers("default") and s.kind == "build")),
        select: %{id: s.id, name: s.name, pane_id: s.pane_id, last_seen_at: s.last_seen_at}
    )
  end

  @doc "Ends rows from `live_default/0` whose pane (or window name, before a pane is known) is gone."
  def end_missing(rows, panes) do
    for row <- rows,
        not Foreman.SessionTargets.present?(panes, row.pane_id || row.name) do
      {:ended, [save: :ended_at]} = ExternalSession.step(:running, :pane_gone, %{})

      # A claim made after the listing changes last_seen_at, so it is not ended here.
      Repo.update_all(
        from(s in AgentSession,
          where:
            s.id == ^row.id and is_nil(s.ended_at) and
              s.last_seen_at == ^row.last_seen_at
        ),
        set: [ended_at: now()]
      )
    end

    :ok
  end

  @doc """
  Where to reach a row in tmux: a board session's planning window (the board's own
  delivery checks it), else its pane, else its window name.
  """
  def target(%AgentSession{tmux_server: "board"} = row) do
    window =
      Repo.one(from p in PlanningSession, where: p.agent_session_id == ^row.id, select: p.window)

    %{server: :board, target: window || row.pane_id || row.name, harness: row.harness}
  end

  def target(%AgentSession{} = row),
    do: %{server: :default, target: row.pane_id || row.name, harness: row.harness}

  def lock(name) when is_binary(name),
    do:
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "foreman:session:" <> name
      ])

  def lock(_), do: :ok

  defp pane(value) when is_binary(value),
    do: if(Regex.match?(~r/\A%\d+\z/, value), do: value)

  defp pane(_), do: nil

  defp text(value) when is_binary(value),
    do: if(String.trim(value) != "", do: value)

  defp text(_), do: nil

  defp now, do: DateTime.utc_now()
end
