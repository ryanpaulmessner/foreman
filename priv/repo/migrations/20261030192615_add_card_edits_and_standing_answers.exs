defmodule Foreman.Repo.Migrations.AddCardEditsAndStandingAnswers do
  use Ecto.Migration

  def change do
    alter table(:approval_requests) do
      add :edited_at, :utc_datetime_usec
    end
  end
end
