defmodule Foreman.Answers.StandingAnswer do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @derive {Jason.Encoder, only: [:id, :repo_key, :question, :options, :answer, :note]}
  schema "standing_answers" do
    field :repo_key, :string
    field :match_key, :string
    field :question, :string
    field :options, {:array, :string}
    field :answer, :string
    field :note, :string
    timestamps(type: :utc_datetime_usec)
  end
end
