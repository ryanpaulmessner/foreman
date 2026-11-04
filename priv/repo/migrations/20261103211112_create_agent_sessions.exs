defmodule Foreman.Repo.Migrations.CreateAgentSessions do
  @moduledoc """
  One identity row per agent session (spec docs/specs/sessions-view.md, Decisions 1, 2 and 6).

  Backfill: one row per registration and per planning session, and one build row per
  (own name, pane) of dispatch rows that stored a `%pane` and the build's own name.
  Requests are not backfilled (D3). Rows that are not live get `ended_at`; at most one
  row per name stays live (the most recently seen), so the partial unique index holds.
  """
  use Ecto.Migration

  def up do
    create table(:agent_sessions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :text, null: false
      add :kind, :text, null: false
      add :parent_id, references(:agent_sessions, type: :uuid, on_delete: :nilify_all)
      add :harness, :text
      add :model, :text
      add :conversation_id, :text
      add :tmux_server, :text
      add :pane_id, :text
      add :project, :text
      add :ticket, :text
      add :workdir, :text
      add :branch, :text
      # Written by the lifecycle machine (fm-9mm.10); liveness here is `ended_at`.
      add :state, :text
      add :started_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
    end

    create constraint(:agent_sessions, :agent_sessions_kind,
             check: "kind IN ('main_coordinator', 'epic_coordinator', 'build')"
           )

    create constraint(:agent_sessions, :agent_sessions_tmux_server,
             check: "tmux_server IS NULL OR tmux_server IN ('board', 'default')"
           )

    create index(:agent_sessions, [:pane_id], where: "ended_at IS NULL")
    create index(:agent_sessions, [:parent_id])

    for table <- [:planning_sessions, :sessions, :approval_requests] do
      alter table(table) do
        add :agent_session_id, references(:agent_sessions, type: :uuid, on_delete: :nilify_all)
      end

      create index(table, [:agent_session_id])
    end

    flush()
    backfill()

    # Created after the backfill has left at most one live row per name.
    create unique_index(:agent_sessions, [:name],
             where: "ended_at IS NULL",
             name: :agent_sessions_live_name_index
           )
  end

  def down do
    for table <- [:planning_sessions, :sessions, :approval_requests] do
      alter table(table) do
        remove :agent_session_id
      end
    end

    drop table(:agent_sessions)
  end

  defp backfill do
    p = "\"" <> (prefix() || "public") <> "\""
    pane = "'^%[0-9]+$'"

    # Registrations: claude names are coordinators ("coordinator" is the main one), pi builds.
    execute("""
    CREATE TEMP TABLE agent_sessions_registered ON COMMIT DROP AS
    SELECT id AS sessions_id, gen_random_uuid() AS id FROM #{p}.sessions
    WHERE repo_key = '__foreman__' AND bead_id = 'registered'
      AND coalesce(details->>'session', '') <> ''
    """)

    execute("""
    INSERT INTO #{p}.agent_sessions
      (id, name, kind, harness, tmux_server, pane_id, workdir, started_at, last_seen_at, ended_at)
    SELECT r.id, details->>'session',
      CASE WHEN details->>'harness' = 'pi' THEN 'build'
           WHEN details->>'session' = 'coordinator' THEN 'main_coordinator'
           ELSE 'epic_coordinator' END,
      details->>'harness', 'default',
      CASE WHEN "window" ~ #{pane} THEN "window" END,
      details->>'workdir', started_at, last_seen_at, ended_at
    FROM #{p}.sessions s JOIN agent_sessions_registered r ON r.sessions_id = s.id
    """)

    execute("""
    UPDATE #{p}.sessions s SET agent_session_id = r.id
    FROM agent_sessions_registered r WHERE r.sessions_id = s.id
    """)

    # Board-launched planning sessions keep their UUID as identity and conversation id.
    execute("""
    INSERT INTO #{p}.agent_sessions
      (id, name, kind, harness, conversation_id, tmux_server, project, ticket, workdir,
       started_at, last_seen_at, ended_at)
    SELECT session_id, ticket,
      CASE WHEN project = '__foreman__' AND ticket = 'coordinator' THEN 'main_coordinator'
           ELSE 'epic_coordinator' END,
      'claude', session_id::text, 'board',
      CASE WHEN project = '__foreman__' THEN NULL ELSE project END,
      CASE WHEN project = '__foreman__' THEN NULL ELSE ticket END,
      workdir, launched_at, coalesce(last_activity_at, observed_at, launched_at),
      CASE WHEN state IN ('ended', 'parked')
           THEN coalesce(last_activity_at, observed_at, launched_at) END
    FROM #{p}.planning_sessions
    """)

    execute("UPDATE #{p}.planning_sessions SET agent_session_id = session_id")

    # Dispatch rows with a pane and the build's own name: not a coordinator's name.
    execute("""
    CREATE TEMP TABLE agent_sessions_dispatch ON COMMIT DROP AS
    SELECT s.id AS sessions_id, s.details->>'session' AS name, s."window" AS pane
    FROM #{p}.sessions s
    WHERE s.repo_key <> '__foreman__' AND s."window" ~ #{pane}
      AND coalesce(s.details->>'session', '') <> ''
      AND s.details->>'session' <> coalesce(s.details->>'coordinator', '')
      AND NOT EXISTS (SELECT 1 FROM #{p}.agent_sessions a
                      WHERE a.name = s.details->>'session' AND a.kind <> 'build')
      AND NOT EXISTS (SELECT 1 FROM #{p}.sessions c
                      WHERE c.repo_key <> '__foreman__'
                        AND c.details->>'coordinator' = s.details->>'session')
    """)

    execute("""
    CREATE TEMP TABLE agent_sessions_builds ON COMMIT DROP AS
    SELECT g.name, g.pane,
      coalesce((SELECT a.id FROM #{p}.agent_sessions a
                WHERE a.kind = 'build' AND a.name = g.name AND a.pane_id = g.pane
                ORDER BY a.started_at DESC LIMIT 1), gen_random_uuid()) AS id
    FROM (SELECT DISTINCT name, pane FROM agent_sessions_dispatch) g
    """)

    execute("""
    INSERT INTO #{p}.agent_sessions (id, name, kind, tmux_server, pane_id, started_at)
    SELECT b.id, b.name, 'build', 'default', b.pane,
      (SELECT min(s.started_at) FROM #{p}.sessions s
       JOIN agent_sessions_dispatch d ON d.sessions_id = s.id
       WHERE d.name = b.name AND d.pane = b.pane)
    FROM agent_sessions_builds b
    WHERE NOT EXISTS (SELECT 1 FROM #{p}.agent_sessions a WHERE a.id = b.id)
    """)

    execute("""
    UPDATE #{p}.sessions s SET agent_session_id = b.id
    FROM agent_sessions_dispatch d JOIN agent_sessions_builds b ON b.name = d.name AND b.pane = d.pane
    WHERE s.id = d.sessions_id
    """)

    # Fill each build from its latest dispatch; registrations keep their own times.
    execute("""
    UPDATE #{p}.agent_sessions a SET
      harness = coalesce(a.harness, l.details->>'harness'),
      model = coalesce(a.model, l.details->>'model'),
      workdir = coalesce(a.workdir, l.details->>'workdir'),
      branch = coalesce(a.branch, l.details->>'branch'),
      project = coalesce(a.project, l.repo_key),
      ticket = coalesce(a.ticket, l.bead_id),
      last_seen_at = greatest(a.last_seen_at, l.max_seen),
      ended_at = CASE WHEN a.ended_at IS NULL AND a.last_seen_at IS NOT NULL THEN NULL
                      WHEN l.open THEN NULL
                      ELSE greatest(a.ended_at, l.max_ended) END
    FROM (
      SELECT DISTINCT ON (s.agent_session_id) s.agent_session_id, s.details, s.repo_key,
        s.bead_id,
        max(s.last_seen_at) OVER w AS max_seen,
        max(s.ended_at) OVER w AS max_ended,
        bool_or(s.ended_at IS NULL) OVER w AS open
      FROM #{p}.sessions s
      WHERE s.repo_key <> '__foreman__' AND s.agent_session_id IS NOT NULL
      WINDOW w AS (PARTITION BY s.agent_session_id)
      ORDER BY s.agent_session_id, s.id DESC
    ) l
    WHERE a.id = l.agent_session_id
    """)

    # Builds: parent is the coordinator named on their latest dispatch.
    execute("""
    UPDATE #{p}.agent_sessions a SET parent_id = (
      SELECT c.id FROM #{p}.agent_sessions c
      WHERE c.kind <> 'build' AND c.id <> a.id AND c.name = l.coordinator
      ORDER BY c.ended_at IS NULL DESC, c.started_at DESC LIMIT 1)
    FROM (
      SELECT DISTINCT ON (agent_session_id) agent_session_id, details->>'coordinator' AS coordinator
      FROM #{p}.sessions
      WHERE repo_key <> '__foreman__' AND agent_session_id IS NOT NULL
      ORDER BY agent_session_id, id DESC
    ) l
    WHERE a.id = l.agent_session_id AND a.kind = 'build' AND l.coordinator IS NOT NULL
    """)

    # Epic coordinators sit under the main coordinator: the live one, else the latest.
    execute("""
    UPDATE #{p}.agent_sessions a SET parent_id = (
      SELECT m.id FROM #{p}.agent_sessions m WHERE m.kind = 'main_coordinator'
      ORDER BY m.ended_at IS NULL DESC, m.started_at DESC LIMIT 1)
    WHERE a.kind = 'epic_coordinator'
    """)

    # At most one live row per name: the most recently seen stays live.
    execute("""
    UPDATE #{p}.agent_sessions a
    SET ended_at = coalesce(a.last_seen_at, a.started_at)
    WHERE a.ended_at IS NULL AND EXISTS (
      SELECT 1 FROM #{p}.agent_sessions b
      WHERE b.name = a.name AND b.ended_at IS NULL AND b.id <> a.id
        AND (coalesce(b.last_seen_at, b.started_at), b.started_at, b.id::text)
          > (coalesce(a.last_seen_at, a.started_at), a.started_at, a.id::text))
    """)
  end
end
