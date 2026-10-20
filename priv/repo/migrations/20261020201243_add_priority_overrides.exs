defmodule Foreman.Repo.Migrations.AddPriorityOverrides do
  use Ecto.Migration

  # A priority set on the board (ticket files are never written by the app). The
  # row wins over the file's value until a file sync carries the same value.
  def change do
    create table(:priority_overrides) do
      add :repo_key, :text, null: false
      add :bead_id, :text, null: false
      add :priority, :integer, null: false
      add :actor, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:priority_overrides, [:repo_key, :bead_id])

    create constraint(:priority_overrides, :priority_range, check: "priority BETWEEN 0 AND 4")
  end
end
