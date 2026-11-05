defmodule Foreman.Repo.Migrations.CreateSessionCaptures do
  @moduledoc """
  The last pane output of each agent session, for the dead view (spec Decision 15; design
  pack Data). One row per session: `output` is the raw `capture-pane -e` text (up to 200
  lines with colour codes), `reason` says when it was saved. No backfill.
  """
  use Ecto.Migration

  def change do
    create table(:session_captures, primary_key: false) do
      add :session_id,
          references(:agent_sessions, type: :uuid, on_delete: :delete_all),
          primary_key: true

      add :output, :text, null: false
      add :reason, :text, null: false
      add :captured_at, :utc_datetime_usec, null: false
    end

    create constraint(:session_captures, :session_captures_reason,
             check: "reason IN ('exit', 'stop', 'park', 'poll')"
           )
  end
end
