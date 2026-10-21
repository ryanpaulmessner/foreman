defmodule Foreman.Repo.Migrations.CreateCardMessages do
  use Ecto.Migration

  def change do
    create table(:card_messages) do
      add :request_id, references(:approval_requests, type: :uuid, on_delete: :delete_all),
        null: false

      add :author, :text, null: false
      add :body, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:card_messages, [:request_id, :id])
  end
end
