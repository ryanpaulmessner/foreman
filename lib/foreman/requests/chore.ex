defmodule Foreman.Requests.Chore do
  @moduledoc "A human task shared by pending asks with the same key across repositories."
  @behaviour Foreman.Requests.Kind
  alias Foreman.Requests.Decision

  @impl true
  def validate(facts, row) when is_map(facts) do
    steps = facts["steps"]

    if Decision.text?(facts["question"]) and is_list(steps) and length(steps) in 1..30 and
         Enum.all?(steps, &Decision.text?/1) and
         (is_nil(facts["key"]) or Decision.text?(facts["key"])) and
         (is_nil(facts["text"]) or Decision.text?(facts["text"])) do
      with {:ok, docs} <- Foreman.CardText.docs(facts["docs"], row.repo_key) do
        {:ok, facts |> Map.take(~w(question text steps key)) |> Map.put("docs", docs)}
      end
    else
      {:error, :invalid_facts}
    end
  end

  def validate(_, _), do: {:error, :invalid_facts}

  @impl true
  def enqueue(_), do: {:error, :chore_not_executable}
end
