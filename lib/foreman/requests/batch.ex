defmodule Foreman.Requests.Batch do
  @moduledoc "One question with a checked subset of items; answers never execute work."
  @behaviour Foreman.Requests.Kind
  alias Foreman.Requests.Decision

  @impl true
  def validate(facts, row) when is_map(facts) do
    items = facts["items"]

    if is_list(items) and length(items) in 2..50 and Enum.all?(items, &item?/1) and
         length(Enum.uniq_by(items, & &1["id"])) == length(items) do
      with {:ok, context} <- Decision.validate(Map.take(facts, ~w(question text docs)), row) do
        {:ok,
         context
         |> Map.drop(~w(options))
         |> Map.put("items", Enum.map(items, &Map.take(&1, ~w(id label detail))))}
      end
    else
      {:error, :invalid_facts}
    end
  end

  def validate(_, _), do: {:error, :invalid_facts}

  defp item?(%{"id" => id, "label" => label} = item),
    do:
      Decision.text?(id) and Decision.text?(label) and
        (is_nil(item["detail"]) or Decision.text?(item["detail"]))

  defp item?(_), do: false

  def answer(request, %{"answer" => ids} = payload) when is_list(ids) do
    allowed = Enum.map(request.facts["items"], & &1["id"])

    if Enum.all?(ids, &(&1 in allowed)) and length(Enum.uniq(ids)) == length(ids),
      do: {:ok, payload},
      else: {:error, :invalid_answer}
  end

  def answer(_, _), do: {:error, :invalid_answer}

  @impl true
  def enqueue(_), do: {:error, :batch_not_executable}
end
