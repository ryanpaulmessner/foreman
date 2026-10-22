defmodule Foreman.Repo.Migrations.AddDesignLinkToEpics do
  use Ecto.Migration

  def change do
    alter table(:epics) do
      add :design_link, :text
    end
  end
end
