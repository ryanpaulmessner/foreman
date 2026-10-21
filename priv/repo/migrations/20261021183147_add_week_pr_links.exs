defmodule Foreman.Repo.Migrations.AddWeekPrLinks do
  use Ecto.Migration

  def change do
    create table(:week_pr_links, primary_key: false) do
      add :repo_key, :text, primary_key: true
      add :remote, :text, primary_key: true
      add :ticket_id, :text, primary_key: true
      add :number, :integer, primary_key: true
      add :url, :text, null: false
      add :base_branch, :text
      add :head_sha, :text, null: false
      add :state, :text, null: false
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
      add :in_production, :boolean
      add :in_staging, :boolean
      add :checked_at, :utc_datetime_usec
    end

    create table(:week_pr_backfills, primary_key: false) do
      add :repo_key, :text, primary_key: true
      add :remote, :text, primary_key: true
      add :completed_at, :utc_datetime_usec, null: false
    end
  end
end
