defmodule Foreman.AgentSession do
  @moduledoc """
  The one identity of an agent session (spec Decision 1). A row is live while
  `ended_at` is null; names are unique among live rows only (Decision 2).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(main_coordinator epic_coordinator build)
  @servers ~w(board default)
  @fields ~w(id name kind parent_id harness model conversation_id tmux_server pane_id project ticket workdir branch started_at last_seen_at)a

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "agent_sessions" do
    field :name, :string
    field :kind, :string
    belongs_to :parent, __MODULE__
    field :harness, :string
    field :model, :string
    field :conversation_id, :string
    field :tmux_server, :string
    field :pane_id, :string
    field :project, :string
    field :ticket, :string
    field :workdir, :string
    field :branch, :string
    # Owned by `Foreman.SessionLifecycle` through `Foreman.AgentSessions.fire/3`;
    # never written by the identity writers.
    field :state, :string
    field :state_at, :utc_datetime_usec
    # The monitor's last pane-activity fingerprint and when it last changed.
    field :output_mark, :string
    field :output_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
  end

  def kinds, do: @kinds

  # Every field is set by the board's own writers, never from request params.
  def changeset(session, attrs) do
    session
    |> change(Map.take(attrs, @fields))
    |> validate_required([:name, :kind, :started_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:tmux_server, @servers)
    |> validate_format(:pane_id, ~r/\A%\d+\z/)
    |> unique_constraint(:name,
      name: :agent_sessions_live_name_index,
      message: "is taken by a live session"
    )
  end
end
