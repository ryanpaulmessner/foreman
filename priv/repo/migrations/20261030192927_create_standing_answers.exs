defmodule Foreman.Repo.Migrations.CreateStandingAnswers do
  use Ecto.Migration

  def change do
    create table(:standing_answers, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :repo_key, :text, null: false
      add :match_key, :text, null: false
      add :question, :text, null: false
      add :options, {:array, :text}, null: false
      add :answer, :text, null: false
      add :note, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:standing_answers, [:repo_key, :match_key])
  end
end
