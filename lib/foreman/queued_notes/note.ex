defmodule Foreman.QueuedNotes.Note do
  @moduledoc """
  A note the board types into a coordinator's pane once its prompt is idle (fm-9mm.23).
  `state` is a `Foreman.QueuedNote` state, written only by `Foreman.QueuedNotes`.
  """
  use Ecto.Schema

  @foreign_key_type :binary_id
  schema "queued_notes" do
    # "answer" (R9 answer to an ended build's card) or "relaunch" (Relaunch build).
    field :kind, :string
    field :state, :string
    belongs_to :coordinator, Foreman.AgentSession
    # The ended session the note is about.
    belongs_to :subject, Foreman.AgentSession
    belongs_to :request, Foreman.Requests.Request
    # The whole message as typed, prefix included.
    field :text, :string
    # Why a note failed: "typing_failed" or "lost".
    field :reason, :string
    field :claimed_at, :utc_datetime_usec
    field :done_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
