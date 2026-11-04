defmodule Foreman.PlanningSession do
  @moduledoc "Durable identity for a board-launched Claude conversation."
  use Ecto.Schema
  @primary_key {:session_id, :binary_id, autogenerate: true}
  schema "planning_sessions" do
    field :project, :string
    field :ticket, :string
    field :window, :string
    field :workdir, :string
    field :state, Ecto.Enum, values: [:starting, :running, :waiting, :ended, :parked]
    field :error, :string
    field :launched_at, :utc_datetime_usec
    field :observed_at, :utc_datetime_usec
    field :last_activity_at, :utc_datetime_usec
    field :previous_windows, {:array, :map}, default: []
    field :agent_session_id, :binary_id
  end
end
