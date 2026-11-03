defmodule Foreman.Requests.Request do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @derive {Jason.Encoder,
           only: [
             :id,
             :repo_key,
             :bead_id,
             :kind,
             :actor,
             :session,
             :agent_session_id,
             :facts,
             :state,
             :outcome,
             :note,
             :edited_at,
             :inserted_at,
             :updated_at
           ]}
  schema "approval_requests" do
    field :repo_key, :string
    field :bead_id, :string
    field :kind, :string
    field :actor, :string
    field :session, :string
    # The asking session, resolved when the ask is accepted (never at render).
    field :agent_session_id, :binary_id
    field :facts, :map
    field :state, :string
    field :outcome, :map, default: %{}
    field :note, :string
    field :edited_at, :utc_datetime_usec
    # The ticket's effective priority, filled for the Needs you list only.
    field :priority, :integer, virtual: true
    field :standing_answer, :map, virtual: true
    field :similar_question, :boolean, virtual: true, default: false
    timestamps(type: :utc_datetime_usec)
  end
end
