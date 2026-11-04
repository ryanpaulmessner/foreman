defmodule Foreman.AgentSessionsMigrationTest do
  # Runs the real migration against a copy of the pre-migration schema in its own prefix.
  use Foreman.DataCase, async: false

  @prefix "agent_sessions_migration"
  @version 20_261_103_211_112
  # Another migration test may have loaded it already (require_file then returns nil).
  Code.require_file("priv/repo/migrations/20261103211112_create_agent_sessions.exs")
  @migration Foreman.Repo.Migrations.CreateAgentSessions

  setup do
    Repo.query!("CREATE SCHEMA #{@prefix}")

    for table <- ~w(sessions planning_sessions approval_requests) do
      Repo.query!(
        "CREATE TABLE #{@prefix}.#{table} (LIKE public.#{table} INCLUDING DEFAULTS INCLUDING CONSTRAINTS)"
      )

      Repo.query!("ALTER TABLE #{@prefix}.#{table} DROP COLUMN agent_session_id")
    end

    Repo.query!("ALTER TABLE #{@prefix}.planning_sessions ADD PRIMARY KEY (session_id)")
    :ok
  end

  defp at(minutes), do: DateTime.add(~U[2026-11-02 12:00:00Z], minutes, :minute)

  defp session(repo, bead, window, details, opts) do
    row = %{
      repo_key: repo,
      bead_id: bead,
      window: window,
      details: details,
      started_at: Keyword.get(opts, :started, at(0)) |> DateTime.to_naive(),
      last_seen_at: Keyword.get(opts, :seen, at(5)) |> DateTime.to_naive(),
      ended_at: if(opts[:ended], do: DateTime.to_naive(opts[:ended]))
    }

    Repo.insert_all("sessions", [row], prefix: @prefix)
  end

  defp registration(name, pane, harness, opts \\ []),
    do:
      session(
        "__foreman__",
        "registered",
        pane,
        %{
          "session" => name,
          "harness" => harness,
          "workdir" => "/w/" <> name
        },
        opts
      )

  defp dispatch(bead, window, details, opts \\ []),
    do:
      session(
        "work",
        bead,
        window,
        Map.merge(%{"harness" => "pi", "model" => "m"}, details),
        opts
      )

  defp planning(id, project, ticket, state) do
    Repo.query!(
      "INSERT INTO #{@prefix}.planning_sessions (session_id, project, ticket, \"window\", workdir, state, launched_at, last_activity_at, previous_windows) VALUES ($1, $2, $3, '@1', '/w', $4, $5, $5, '{}')",
      [Ecto.UUID.dump!(id), project, ticket, state, at(0)]
    )
  end

  defp rows(sql), do: Repo.query!(sql).rows

  test "creates the table and index, backfills registrations, planning rows and own-name pane dispatches" do
    main = Ecto.UUID.generate()
    epic = Ecto.UUID.generate()

    # Registrations: the main coordinator (and an alias on its pane), an epic coordinator,
    # a live build and an ended one.
    registration("coordinator", "%1", "claude")
    registration("main", "%1", "claude")
    registration("ai-chat", "%2", "claude")
    registration("build-a", "%10", "pi")
    registration("build-old", "%11", "pi", ended: at(30))

    planning(main, "__foreman__", "coordinator", "ended")
    planning(epic, "work", "work-71b", "parked")
    planning(Ecto.UUID.generate(), "work", "draft:health", "running")

    # Dispatches: build-a's two tickets on its registered pane (one row), a pane build with
    # no registration, then rows that are skipped: the coordinator's name, a window name,
    # no session, and a name that is some build's coordinator.
    dispatch("w-1", "%10", %{"session" => "build-a", "coordinator" => "ai-chat"}, ended: at(20))
    dispatch("w-2", "%10", %{"session" => "build-a", "coordinator" => "ai-chat"})
    dispatch("w-3", "%12", %{"session" => "build-b", "coordinator" => "ai-chat"}, ended: at(40))
    dispatch("w-4", "%13", %{"session" => "ai-chat"}, ended: at(40))
    dispatch("w-5", "build-c", %{"session" => "build-c"}, ended: at(40))
    dispatch("w-6", "%14", %{}, ended: at(40))
    dispatch("w-7", "%15", %{"session" => "lead", "coordinator" => "lead"}, ended: at(40))
    dispatch("w-8", "%16", %{"session" => "lead2"}, ended: at(40))
    dispatch("w-9", "%17", %{"session" => "b9", "coordinator" => "lead2"}, ended: at(40))

    # Requests are not backfilled.
    Repo.query!(
      "INSERT INTO #{@prefix}.approval_requests (id, repo_key, bead_id, kind, actor, session, facts, state, inserted_at, updated_at) VALUES (gen_random_uuid(), 'work', 'w-1', 'decision', 'pi', 'build-a', '{}', 'pending', now(), now())"
    )

    assert :ok =
             Ecto.Migrator.up(Repo, @version, @migration,
               prefix: @prefix,
               log: false,
               migration_lock: false
             )

    # 5 registrations + 3 planning rows + 2 dispatch-only builds (build-b, b9).
    assert [[10]] = rows("SELECT count(*) FROM #{@prefix}.agent_sessions")

    assert rows(
             "SELECT name, kind, pane_id, tmux_server, ended_at IS NULL FROM #{@prefix}.agent_sessions ORDER BY name, tmux_server"
           ) == [
             ["ai-chat", "epic_coordinator", "%2", "default", true],
             ["b9", "build", "%17", "default", false],
             ["build-a", "build", "%10", "default", true],
             ["build-b", "build", "%12", "default", false],
             ["build-old", "build", "%11", "default", false],
             ["coordinator", "main_coordinator", nil, "board", false],
             ["coordinator", "main_coordinator", "%1", "default", true],
             ["draft:health", "epic_coordinator", nil, "board", true],
             ["main", "epic_coordinator", "%1", "default", true],
             ["work-71b", "epic_coordinator", nil, "board", false]
           ]

    # build-a: both dispatch rows and the registration point at one row, filled from the
    # latest dispatch, under the coordinator named on it.
    assert [[ticket, model, parent]] =
             rows("""
             SELECT a.ticket, a.model, p.name FROM #{@prefix}.agent_sessions a
             LEFT JOIN #{@prefix}.agent_sessions p ON p.id = a.parent_id WHERE a.name = 'build-a'
             """)

    assert {ticket, model, parent} == {"w-2", "m", "ai-chat"}

    assert [[3]] =
             rows("""
             SELECT count(*) FROM #{@prefix}.sessions s
             JOIN #{@prefix}.agent_sessions a ON a.id = s.agent_session_id WHERE a.name = 'build-a'
             """)

    # Skipped dispatch rows have no identity.
    assert rows("""
           SELECT bead_id FROM #{@prefix}.sessions
           WHERE repo_key = 'work' AND agent_session_id IS NULL ORDER BY bead_id
           """) == [["w-4"], ["w-5"], ["w-6"], ["w-7"], ["w-8"]]

    # Planning rows keep their UUID; epic coordinators sit under the live main coordinator.
    assert [[^epic, "%1"]] =
             rows("""
             SELECT a.id::text, p.pane_id FROM #{@prefix}.agent_sessions a
             JOIN #{@prefix}.agent_sessions p ON p.id = a.parent_id WHERE a.name = 'work-71b'
             """)

    assert [[3]] =
             rows(
               "SELECT count(*) FROM #{@prefix}.planning_sessions WHERE agent_session_id = session_id"
             )

    assert [[0]] =
             rows(
               "SELECT count(*) FROM #{@prefix}.approval_requests WHERE agent_session_id IS NOT NULL"
             )

    assert [[1]] =
             rows("""
             SELECT count(*) FROM pg_indexes WHERE schemaname = '#{@prefix}'
               AND indexname = 'agent_sessions_live_name_index'
               AND indexdef LIKE '%UNIQUE%' AND indexdef LIKE '%ended_at IS NULL%'
             """)

    assert :ok =
             Ecto.Migrator.down(Repo, @version, @migration,
               prefix: @prefix,
               log: false,
               migration_lock: false
             )

    assert [[nil]] = rows("SELECT to_regclass('#{@prefix}.agent_sessions')::text")

    assert [[0]] =
             rows("""
             SELECT count(*) FROM information_schema.columns
             WHERE table_schema = '#{@prefix}' AND column_name = 'agent_session_id'
             """)
  end

  test "two live registrations of one name leave the most recently seen one live" do
    registration("dup", "%1", "claude", seen: at(5))
    registration("dup", "%2", "claude", seen: at(9))

    assert :ok =
             Ecto.Migrator.up(Repo, @version, @migration,
               prefix: @prefix,
               log: false,
               migration_lock: false
             )

    assert rows(
             "SELECT pane_id, ended_at IS NULL FROM #{@prefix}.agent_sessions ORDER BY pane_id"
           ) == [["%1", false], ["%2", true]]
  end
end
