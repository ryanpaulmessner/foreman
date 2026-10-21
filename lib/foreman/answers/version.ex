defmodule Foreman.Answers.Version do
  use Ecto.Schema
  import Ecto.Changeset

  schema "answer_versions" do
    belongs_to :answer, Foreman.Answers.Answer, type: :binary_id
    field :question, :string
    field :body, :string
    field :repo, :string
    field :ticket, :string
    field :links, {:array, :string}, default: []
    field :actor, :string
    field :session, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(version, attrs) do
    version
    |> cast(attrs, [:question, :body, :repo, :ticket, :links, :actor, :session])
    |> validate_required([:question, :body, :actor])
    |> validate_length(:question, max: 10_000)
    |> validate_length(:body, max: 1_048_576)
    |> validate_length(:links, max: 20)
    |> validate_links()
  end

  defp validate_links(changeset) do
    links = get_field(changeset, :links)

    if is_list(links) and Enum.all?(links, &(is_binary(&1) and byte_size(&1) in 1..4096)),
      do: changeset,
      else: add_error(changeset, :links, "must contain paths or URLs of 1 to 4096 bytes")
  end
end
