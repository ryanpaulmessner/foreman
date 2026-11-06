defmodule Foreman.Repo.Migrations.CreateQueuedNotes do
  use Ecto.Migration

  def change do
    # A note for a coordinator that was busy (fm-9mm.23); `state` is a Foreman.QueuedNote state.
    create table(:queued_notes) do
      add :kind, :text, null: false
      add :state, :text, null: false

      add :coordinator_id, references(:agent_sessions, type: :uuid, on_delete: :delete_all),
        null: false

      add :subject_id, references(:agent_sessions, type: :uuid, on_delete: :nilify_all)
      add :request_id, references(:approval_requests, type: :uuid, on_delete: :nilify_all)
      add :text, :text, null: false
      add :reason, :text
      add :claimed_at, :utc_datetime_usec
      add :done_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:queued_notes, :queued_notes_kind, check: "kind IN ('answer', 'relaunch')")

    create constraint(:queued_notes, :queued_notes_state,
             check: "state IN ('queued', 'sending', 'sent', 'failed', 'withdrawn')"
           )

    create index(:queued_notes, [:coordinator_id], where: "state IN ('queued', 'sending')")
    create unique_index(:queued_notes, [:request_id], where: "request_id IS NOT NULL")

    # One open Relaunch build note per build: pressing it again while one waits adds none.
    create unique_index(:queued_notes, [:subject_id],
             name: :queued_notes_open_relaunch_index,
             where: "kind = 'relaunch' AND state IN ('queued', 'sending')"
           )
  end
end
