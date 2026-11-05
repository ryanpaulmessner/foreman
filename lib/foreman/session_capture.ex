defmodule Foreman.SessionCapture do
  @moduledoc "The last saved pane output of one agent session (spec Decision 15)."
  use Ecto.Schema

  @reasons ~w(exit stop park poll)

  @primary_key {:session_id, :binary_id, autogenerate: false}
  schema "session_captures" do
    field :output, :string
    field :reason, :string
    field :captured_at, :utc_datetime_usec
  end

  def reasons, do: @reasons
end
