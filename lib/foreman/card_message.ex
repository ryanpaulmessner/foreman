defmodule Foreman.CardMessage do
  use Ecto.Schema

  schema "card_messages" do
    field :request_id, Ecto.UUID
    field :author, :string
    field :body, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
