defmodule Foreman.Repo.Migrations.CreateCloseOutNags do
  use Ecto.Migration

  def change do
    # One row per ticket with stuck agent close-out work; `state` is a Foreman.CloseOutNag state.
    create table(:close_out_nags) do
      add :repo_key, :text, null: false
      add :bead_id, :text, null: false
      add :kind, :text, null: false
      add :state, :text, null: false
      add :fingerprint, :text, null: false
      add :stuck_since, :utc_datetime_usec, null: false
      add :last_noted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:close_out_nags, [:repo_key, :bead_id])

    # Every note attempt, delivered or not, with the reason when it did not reach the owner.
    create table(:close_out_nag_notes) do
      add :repo_key, :text, null: false
      add :bead_id, :text, null: false
      add :kind, :text, null: false
      add :owner, :text
      add :result, :text, null: false
      add :reason, :text
      add :text, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:close_out_nag_notes, [:repo_key, :bead_id])
  end
end
