defmodule Foreman.Repo.Migrations.CreateAnswers do
  use Ecto.Migration

  def change do
    create table(:answers, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :state, :text, null: false, default: "normal"
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:answers, :answer_state,
             check: "state IN ('normal', 'pinned', 'archived', 'archived_pinned')"
           )

    create table(:answer_versions) do
      add :answer_id, references(:answers, type: :uuid, on_delete: :restrict), null: false
      add :question, :text, null: false
      add :body, :text, null: false
      add :repo, :text
      add :ticket, :text
      add :links, {:array, :text}, null: false, default: []
      add :actor, :text, null: false
      add :session, :text
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:answer_versions, [:answer_id, :id])
  end
end
