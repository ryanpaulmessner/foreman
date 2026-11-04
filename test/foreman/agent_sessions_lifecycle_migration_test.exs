defmodule Foreman.AgentSessionsLifecycleMigrationTest do
  # Runs the identity migration and then the lifecycle backfill in their own prefix.
  use Foreman.DataCase, async: false

  @prefix "agent_sessions_lifecycle_migration"
  @identity 20_261_103_211_112
  @lifecycle 20_261_104_152_616
  # The identity migration test may have loaded it already (require_file then returns nil).
  Code.require_file("priv/repo/migrations/20261103211112_create_agent_sessions.exs")
  Code.require_file("priv/repo/migrations/20261104152616_add_lifecycle_to_agent_sessions.exs")
  @identity_migration Foreman.Repo.Migrations.CreateAgentSessions
  @lifecycle_migration Foreman.Repo.Migrations.AddLifecycleToAgentSessions

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
  defp rows(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp registration(name, pane, opts) do
    Repo.insert_all(
      "sessions",
      [
        %{
          repo_key: "__foreman__",
          bead_id: "registered",
          window: pane,
          details: %{"session" => name, "harness" => "pi", "workdir" => "/w"},
          started_at: DateTime.to_naive(at(0)),
          last_seen_at: DateTime.to_naive(at(5)),
          ended_at: if(opts[:ended], do: DateTime.to_naive(opts[:ended]))
        }
      ],
      prefix: @prefix
    )
  end

  defp planning(project, ticket, state) do
    Repo.query!(
      "INSERT INTO #{@prefix}.planning_sessions (session_id, project, ticket, \"window\", workdir, state, launched_at, last_activity_at, previous_windows) VALUES ($1, $2, $3, '@1', '/w', $4, $5, $5, '{}')",
      [Ecto.UUID.dump!(Ecto.UUID.generate()), project, ticket, state, at(0)]
    )
  end

  defp migrate(direction, version, migration),
    do:
      apply(Ecto.Migrator, direction, [
        Repo,
        version,
        migration,
        [prefix: @prefix, log: false, migration_lock: false]
      ])

  test "backfill: live rows start, dead rows end, parked epic coordinators park; down reverts" do
    registration("live", "%1", [])
    registration("gone", "%2", ended: at(7))
    planning("sample", "s-1", "parked")
    planning("__foreman__", "coordinator", "ended")
    assert :ok = migrate(:up, @identity, @identity_migration)
    assert :ok = migrate(:up, @lifecycle, @lifecycle_migration)

    assert rows(
             "SELECT name, state, state_at IS NOT NULL FROM #{@prefix}.agent_sessions ORDER BY name"
           ) ==
             [
               ["coordinator", "ended", true],
               ["gone", "ended", true],
               ["live", "starting", true],
               ["s-1", "parked", true]
             ]

    # A live state with ended_at, or an unknown state, is refused.
    assert_raise Postgrex.Error, ~r/agent_sessions_state_liveness_check/, fn ->
      Repo.transaction(fn ->
        Repo.query!("UPDATE #{@prefix}.agent_sessions SET state = 'working' WHERE name = 'gone'")
      end)
    end

    assert_raise Postgrex.Error, ~r/agent_sessions_state_check/, fn ->
      Repo.transaction(fn ->
        Repo.query!("UPDATE #{@prefix}.agent_sessions SET state = 'running' WHERE name = 'live'")
      end)
    end

    assert :ok = migrate(:down, @lifecycle, @lifecycle_migration)

    assert [[0]] =
             rows("""
             SELECT count(*) FROM information_schema.columns
             WHERE table_schema = '#{@prefix}' AND table_name = 'agent_sessions'
               AND column_name IN ('state_at', 'output_at', 'output_mark')
             """)

    assert [[nil]] = rows("SELECT DISTINCT state FROM #{@prefix}.agent_sessions")
  end
end
