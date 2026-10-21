defmodule Foreman.Answers.Answer do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "answers" do
    field :state, Ecto.Enum,
      values: [:normal, :pinned, :archived, :archived_pinned],
      default: :normal

    has_many :versions, Foreman.Answers.Version
    timestamps(type: :utc_datetime_usec)
  end
end
