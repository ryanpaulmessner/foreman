defmodule Foreman.AgentSessions do
  @moduledoc """
  Session identity (spec Decisions 1-6): lookups by id, live name and live pane, the
  writers (registration, dispatch, board launch) and ask resolution.

  A row is live while `ended_at` is null. `Foreman.SessionLifecycle` owns `state` and
  `ended_at` (Decision 7): every change goes through `fire/3`, which saves the state
  and broadcasts `:sessions_changed`. A writer that claims a live name on another pane
  or server ends the older row first, so the partial unique index (Decision 2) holds.
  """
  import Ecto.Query
  alias Foreman.{AgentSession, PlanningSession, Repo, SessionLifecycle}

  @coordinators ~w(main_coordinator epic_coordinator)
  # Decision 7: no output change for 2 minutes is quiet.
  @quiet 120
  @main_name "coordinator"

  def get(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(AgentSession, uuid)
      :error -> nil
    end
  end

  def get(_), do: nil

  @doc "All identities for a ticket, newest first, including ended sessions."
  def for_ticket({project, ticket}) do
    Repo.all(
      from s in AgentSession,
        where: s.project == ^project and s.ticket == ^ticket,
        order_by: [desc: s.started_at, desc: s.id]
    )
  end

  @doc "The epic's live coordinator, else its latest; includes named registrations without ticket metadata."
  def epic_coordinator({project, ticket}) do
    Repo.one(
      from s in AgentSession,
        where:
          s.kind == "epic_coordinator" and
            ((s.project == ^project and s.ticket == ^ticket) or
               (s.name == ^ticket and is_nil(s.project) and is_nil(s.ticket))),
        order_by: [desc: is_nil(s.ended_at), desc: s.started_at, desc: s.id],
        limit: 1
    )
  end

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

  @doc """
  Inserts a live row in `starting`: the machine's `register` step, or `launch` for a
  board launch. A second live row with the same name is refused by the index.
  """
  def create(attrs, event \\ :register) do
    attrs = Map.put_new(attrs, :started_at, now())
    {state, _effects} = SessionLifecycle.step(:none, event, guard_data(attrs))

    with {:ok, row} <-
           %AgentSession{state: SessionLifecycle.dump(state), state_at: now()}
           |> AgentSession.changeset(attrs)
           |> Repo.insert() do
      changed(row)
      {:ok, row}
    end
  end

  @doc """
  Ends a live row with an observed end (`pane_gone` by default, or `exited`); ended rows
  stay ended (a later claim of the name makes a new row).
  """
  def end_session(session, at \\ nil, event \\ :pane_gone)

  def end_session(%AgentSession{ended_at: nil} = session, at, event) do
    {:ok, row, _effects} = fire(session, event, at: at)
    if is_nil(row.ended_at), do: end_session(row, at, :exited), else: row
  end

  def end_session(session, _, _), do: session

  @doc """
  Steps the row's lifecycle (spec Decision 7) under the session-name lock and a row lock,
  and saves the new state. Entering parked or ended sets `ended_at`; leaving them clears
  it. Returns `{:ok, row, effects}` (an ignored observation returns the row unchanged and
  `[]`), `{:error, {:invalid, state, event}}` for a refused claim, `{:error, :name_taken}`
  when another live row holds the name (R7), or `{:error, :not_found}`.

  The caller runs the effects. Options: `:at` (when the new state began, default now),
  `:data` (extra guard data, such as `resumable`) and `:run`, a function of the stepped
  row and its effects that runs them inside the same transaction and row lock: when it
  returns `{:error, reason}` the state change rolls back and `fire/3` returns that error
  (Stop and Park save the capture and close the pane before the row is dead).
  """
  def fire(row_or_id, event, opts \\ [])

  def fire(%AgentSession{id: id}, event, opts), do: fire(id, event, opts)

  def fire(id, event, opts) when is_binary(id) do
    transaction(fn ->
      with %AgentSession{} = row <- locked(id),
           {:ok, row, effects} <- step(row, event, opts) do
        run_effects(Keyword.get(opts, :run), row, effects)
      else
        nil -> {:error, :not_found}
        error -> error
      end
    end)
  end

  defp run_effects(nil, row, effects), do: {:ok, row, effects}

  defp run_effects(run, row, effects) do
    case run.(row, effects) do
      :ok -> {:ok, row, effects}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp locked(id) do
    case get(id) do
      nil ->
        nil

      %AgentSession{name: name} ->
        lock(name)
        Repo.one(from s in AgentSession, where: s.id == ^id, lock: "FOR UPDATE")
    end
  end

  defp step(row, event, opts) do
    from = SessionLifecycle.load(row.state)
    data = Map.merge(guard_data(row, event), Keyword.get(opts, :data, %{}))

    case SessionLifecycle.step(from, event, data) do
      {:error, _} = refused ->
        refused

      {^from, effects} ->
        {:ok, row, effects}

      {to, effects} ->
        at = Keyword.get(opts, :at) || now()
        live? = SessionLifecycle.live?(to)

        if live? and not is_nil(row.ended_at) and taken?(row) do
          {:error, :name_taken}
        else
          ended_at =
            cond do
              live? -> nil
              row.ended_at -> row.ended_at
              true -> at
            end

          # A dead session that lives again (Resume): its old save describes the last run.
          if live? and not is_nil(row.ended_at), do: Foreman.SessionCaptures.clear(row.id)

          row =
            row
            |> Ecto.Changeset.change(
              state: SessionLifecycle.dump(to),
              state_at: at,
              ended_at: ended_at
            )
            |> Repo.update!()

          changed(row)
          {:ok, row, effects}
        end
    end
  end

  @doc "Whether the lifecycle accepts `event` for `row` now, with the same guard data as `fire/3`."
  def allowed?(%AgentSession{} = row, event) do
    state = SessionLifecycle.load(row.state)
    not match?({:error, _}, SessionLifecycle.step(state, event, guard_data(row, event)))
  end

  @doc """
  A resumed or new session's pane (Decision 20): the row keeps its id, `pane_id` changes.
  `last_seen_at` moves too, so a monitor listing read before the pane opened never ends it.
  """
  def opened_pane(%AgentSession{} = row, pane) do
    row
    |> Ecto.Changeset.change(
      pane_id: pane,
      last_seen_at: now(),
      output_mark: nil,
      output_at: nil
    )
    |> Repo.update!()
  end

  @doc """
  The coordinator a session reports to now: its parent while that is live, else the live
  coordinator that took the parent's name (Start fresh), else the dead parent. Nil when
  the row has no parent.
  """
  def coordinator(%AgentSession{parent_id: nil}), do: nil

  def coordinator(%AgentSession{parent_id: parent_id}) do
    case get(parent_id) do
      nil ->
        nil

      %AgentSession{ended_at: nil} = parent ->
        parent

      parent ->
        case live_by_name(parent.name) do
          %AgentSession{kind: kind} = successor when kind in @coordinators -> successor
          _ -> parent
        end
    end
  end

  @doc """
  Start fresh (Decision 7): the live sessions under `old` move to `new`, so its builds
  stay under the coordinator's name. Returns how many moved.
  """
  def move_children(%AgentSession{id: old}, %AgentSession{id: new} = row) do
    {count, _} =
      Repo.update_all(
        from(s in AgentSession, where: s.parent_id == ^old and is_nil(s.ended_at)),
        set: [parent_id: new]
      )

    changed(row)
    count
  end

  defp taken?(row) do
    case live_by_name(row.name) do
      %AgentSession{id: id} when id != row.id -> true
      _ -> false
    end
  end

  defp guard_data(row, event \\ nil) do
    data = %{kind: Map.get(row, :kind), harness: Map.get(row, :harness)}

    cond do
      event in [:resume, :start_fresh, :relaunch_build] ->
        Map.put(data, :resumable, resumable?(row))

      event == :resume_on_model ->
        fallback? = not is_nil(Foreman.SessionFallback.model(row)) and resumable?(row)

        Map.merge(data, %{
          fallback: fallback?,
          family_limit: row.harness == "claude" and fallback?
        })

      true ->
        data
    end
  end

  # Notifications go out at commit; the tree reloads rows from Postgres.
  defp changed(row), do: Foreman.Events.broadcast(:sessions_changed, row.id)

  @doc """
  Whether a dead row can resume its own conversation (R4, fm-9mm.2): Claude needs the
  conversation id; Pi needs the Pi session id, its worktree and the Pi session file.
  """
  def resumable?(%{harness: "pi", conversation_id: id, workdir: dir})
      when is_binary(id) and is_binary(dir) do
    File.dir?(dir) and
      Path.wildcard(Path.join([pi_sessions_dir(), pi_project(dir), "*_" <> id <> ".jsonl"])) != []
  end

  def resumable?(%{harness: "claude", conversation_id: id}) when is_binary(id), do: id != ""
  def resumable?(_), do: false

  defp pi_sessions_dir,
    do: Application.get_env(:foreman, :pi_sessions_dir, Path.expand("~/.pi/agent/sessions"))

  # Pi names a project's session directory after its cwd: `/a/b` is `--a-b--`.
  defp pi_project(dir),
    do: "--" <> (dir |> String.trim_leading("/") |> String.replace("/", "-")) <> "--"

  @doc """
  The monitor's output observer for one live row: `mark` fingerprints the pane's
  activity in this tick's tmux listing. A changed mark fires `output_changed`; an
  unchanged one for 2 minutes fires `quiet` (Decision 7). `:now` injects the clock.
  """
  def observe_output(id, mark, opts \\ []) when is_binary(mark) do
    now = Keyword.get(opts, :now) || now()

    transaction(fn ->
      case locked(id) do
        %AgentSession{ended_at: nil, output_mark: ^mark, output_at: at} = row
        when not is_nil(at) ->
          if DateTime.diff(now, at, :second) >= @quiet,
            do: step(row, :quiet, at: at),
            else: {:ok, row, []}

        %AgentSession{ended_at: nil} = row ->
          row
          |> Ecto.Changeset.change(output_mark: mark, output_at: now)
          |> Repo.update!()
          |> step(:output_changed, at: now)

        _ ->
          {:ok, nil, []}
      end
    end)
  end

  @doc """
  The row a card names. A coordinator posts a Pi build's usage limit for it (when
  `pi-wait` exits LIMITED), so that card names the live build it started on the ticket
  (Decision 7); every other card names its asker.
  """
  def card_owner(
        %AgentSession{kind: kind} = asker,
        "session_waiting",
        %{"reason" => "usage_limit"},
        {repo, ticket}
      )
      when kind in @coordinators do
    Repo.one(
      from s in AgentSession,
        where:
          s.parent_id == ^asker.id and s.kind == "build" and is_nil(s.ended_at) and
            s.project == ^repo and s.ticket == ^ticket,
        order_by: [desc: s.started_at],
        limit: 1
    ) || asker
  end

  def card_owner(asker, _kind, _facts, _key), do: asker

  @doc """
  An accepted card from this row (Decision 7): a permission prompt or usage limit from
  `Foreman.SessionWaiting`, else `asked`. Runs in the request's transaction.
  """
  def card_opened(%{agent_session_id: nil}), do: :ok

  def card_opened(%{agent_session_id: id, kind: kind, facts: facts}) do
    event =
      case {kind, facts["reason"]} do
        {"session_waiting", "permission"} -> :permission_prompt
        {"session_waiting", "usage_limit"} -> :usage_limit
        _ -> :asked
      end

    fire(id, event)
    :ok
  end

  @doc """
  A card from this row left pending: a closed permission request is `prompt_cleared`;
  the last open card closing is `last_card_closed` (Decision 7).
  """
  def card_closed(%{agent_session_id: nil}), do: :ok

  def card_closed(%{agent_session_id: id, kind: kind, facts: facts}) do
    if kind == "session_waiting" and facts["reason"] == "permission",
      do: fire(id, :prompt_cleared)

    if open_cards(id) == [], do: fire(id, :last_card_closed)
    :ok
  end

  @doc "The row's pending requests, oldest first: its open cards (R2)."
  def open_cards(id) do
    Repo.all(
      from r in Foreman.Requests.Request,
        where: r.agent_session_id == ^id and r.state == "pending",
        order_by: [asc: r.inserted_at]
    )
  end

  @doc """
  What the shared state function (`ForemanWeb.SessionState.view/2`) reads for a row: its
  state and times, its open cards, its ticket's stage and, for a live build, when its
  coordinator ended (R8).
  """
  def label_facts(%AgentSession{} = row) do
    cards = open_cards(row.id)
    limit = Enum.find(cards, &(&1.facts["reason"] == "usage_limit"))
    parent = if row.parent_id && is_nil(row.ended_at), do: get(row.parent_id)

    %{
      state: row.state,
      kind: row.kind,
      open_cards: length(cards),
      card_at: cards |> List.first() |> then(&(&1 && &1.inserted_at)),
      stage: if(row.project && row.ticket, do: stage(row.project, row.ticket)),
      state_at: row.state_at,
      ended_at: row.ended_at,
      reset_at: if(limit, do: limit.facts["reset_at"]),
      parent_ended_at: if(parent, do: parent.ended_at)
    }
  end

  defp stage(project, ticket) do
    case Foreman.Overlay.get({project, ticket}) do
      %{stage: stage} -> stage
      _ -> nil
    end
  end

  @doc "A hook saw the agent work (tool use, a resumed turn): output now, without a mark."
  def saw_output(id, opts \\ []) do
    now = Keyword.get(opts, :now) || now()

    transaction(fn ->
      case locked(id) do
        %AgentSession{ended_at: nil} = row ->
          row
          |> Ecto.Changeset.change(output_at: now)
          |> Repo.update!()
          |> step(:output_changed, at: now)

        _ ->
          {:ok, nil, []}
      end
    end)
  end

  @doc """
  Output observation for default-server rows from the tick's one pane listing
  (`Foreman.SessionTargets.list/1`); rows whose pane is not listed are left to
  `end_missing/2`.
  """
  def observe_panes(rows, panes, opts \\ []) do
    for row <- rows,
        pane = listed(panes, row),
        mark = pane_mark(pane),
        do: observe_output(row.id, mark, opts)

    :ok
  end

  defp listed(panes, %{pane_id: pane}) when is_binary(pane),
    do: Enum.find(panes, &(&1.pane == pane))

  defp listed(panes, %{name: name}) do
    case Enum.filter(panes, &(&1.name == name and &1.active)) do
      [pane] -> pane
      _ -> nil
    end
  end

  @doc """
  A pane's activity fingerprint. A window with one pane uses tmux's window activity
  time, which moves on every byte of output. In a shared window (pane-mode builds)
  that time moves for every pane, so the pane's own history size and cursor are used.
  """
  def pane_mark(%{panes: "1", activity: activity}), do: "w:" <> activity
  def pane_mark(%{history: h, cursor: c}), do: "p:" <> h <> ":" <> c
  def pane_mark(_), do: nil

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
  live while the planning session is starting, running or waiting. `:event` names the
  `Foreman.SessionMachine` event that moved the planning session, so the row takes the
  matching lifecycle event in the same transaction (Decision 7): `idle_timeout` parks,
  `window_gone` is `pane_gone` (ended, while the planning row parks), the rest `exited`;
  a planning session live again resumes the row.
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
          {:ok, row} = create(planning_fields(planning, opts), :launch)
          row

        is_nil(row) ->
          {:ok, row} = create(planning_fields(planning, opts), :launch)
          end_session(row, nil, dead_event(planning, opts[:event]))

        live? and row.ended_at ->
          # A resumed conversation keeps its row; the name is claimed again.
          other = live_by_name(row.name)
          if other && other.id != row.id, do: end_session(other)
          {:ok, row, _} = fire(row, :resume, data: %{resumable: true})
          touch(row, %{pane_id: opts[:pane] || row.pane_id})

        not live? and is_nil(row.ended_at) ->
          end_session(row, nil, dead_event(planning, opts[:event]))

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

  defp dead_event(_planning, :idle_timeout), do: :idle_timeout
  defp dead_event(_planning, :window_gone), do: :pane_gone
  defp dead_event(%PlanningSession{state: :parked}, nil), do: :idle_timeout
  defp dead_event(_planning, _), do: :exited

  defp planning_fields(planning, opts) do
    main? = Foreman.Sessions.coordinator?(planning)
    parent = if main?, do: nil, else: main_coordinator()

    %{
      id: planning.session_id,
      name: planning.ticket,
      kind: if(main?, do: "main_coordinator", else: "epic_coordinator"),
      parent_id: parent && parent.id,
      harness: "claude",
      model: parent && parent.model,
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
      transaction(fn ->
        lock(row.name)

        # A claim made after the listing changes last_seen_at, so it is not ended here.
        case Repo.one(
               from s in AgentSession,
                 where:
                   s.id == ^row.id and is_nil(s.ended_at) and
                     s.last_seen_at == ^row.last_seen_at,
                 lock: "FOR UPDATE"
             ) do
          nil -> :ok
          current -> step(current, :pane_gone, [])
        end
      end)
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

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp now, do: DateTime.utc_now()
end
