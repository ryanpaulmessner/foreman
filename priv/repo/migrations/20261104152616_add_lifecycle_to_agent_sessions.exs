defmodule Foreman.Repo.Migrations.AddLifecycleToAgentSessions do
  use Ecto.Migration

  # `Foreman.SessionLifecycle` owns `state` from here on (spec Decision 7). Rows that
  # exist already start where their liveness says: live rows are `starting` until the
  # monitor sees their output, dead rows are `ended`, or `parked` for an epic
  # coordinator whose planning session is parked.
  def up do
    p = prefix() || "public"

    alter table(:agent_sessions) do
      add :state_at, :utc_datetime_usec
      add :output_at, :utc_datetime_usec
      add :output_mark, :text
    end

    execute("""
    UPDATE #{p}.agent_sessions a SET
      state = CASE
        WHEN a.ended_at IS NULL THEN 'starting'
        WHEN a.kind = 'epic_coordinator' AND EXISTS (
          SELECT 1 FROM #{p}.planning_sessions ps
          WHERE ps.agent_session_id = a.id AND ps.state = 'parked') THEN 'parked'
        ELSE 'ended' END,
      state_at = coalesce(a.ended_at, a.last_seen_at, a.started_at)
    """)

    execute("ALTER TABLE #{p}.agent_sessions ALTER COLUMN state SET NOT NULL")
    execute("ALTER TABLE #{p}.agent_sessions ALTER COLUMN state_at SET NOT NULL")

    create constraint(:agent_sessions, :agent_sessions_state_check,
             check:
               "state IN ('starting', 'working', 'idle', 'waiting.question', " <>
                 "'waiting.permission', 'waiting.usage_limit', 'parked', 'ended')"
           )

    # Live means a live state; the partial unique name index reads ended_at.
    create constraint(:agent_sessions, :agent_sessions_state_liveness_check,
             check: "(state IN ('parked', 'ended')) = (ended_at IS NOT NULL)"
           )
  end

  def down do
    drop constraint(:agent_sessions, :agent_sessions_state_liveness_check)
    drop constraint(:agent_sessions, :agent_sessions_state_check)
    execute("ALTER TABLE #{prefix() || "public"}.agent_sessions ALTER COLUMN state DROP NOT NULL")
    execute("UPDATE #{prefix() || "public"}.agent_sessions SET state = NULL")

    alter table(:agent_sessions) do
      remove :state_at
      remove :output_at
      remove :output_mark
    end
  end
end
