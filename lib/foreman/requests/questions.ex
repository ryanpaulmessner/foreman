defmodule Foreman.Requests.Questions do
  @moduledoc "Question matching ignores case, punctuation and spacing; similarity uses word-set overlap."

  def normalize(text) when is_binary(text) do
    text |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]+/u, " ") |> String.trim()
  end

  def normalize(_), do: ""

  def close?(left, right) do
    left = normalize(left)
    right = normalize(right)
    a = MapSet.new(String.split(left))
    b = MapSet.new(String.split(right))

    left != "" and right != "" and
      (left == right or
         MapSet.size(MapSet.intersection(a, b)) / MapSet.size(MapSet.union(a, b)) >= 0.8)
  end

  def flag(requests) do
    Enum.map(requests, fn request ->
      similar =
        Enum.any?(requests, fn other ->
          other.id != request.id and other.repo_key == request.repo_key and
            other.bead_id == request.bead_id and other.kind == request.kind and
            other.state == "pending" and request.state == "pending" and
            close?(request.facts["question"], other.facts["question"])
        end)

      %{request | similar_question: similar}
    end)
  end
end
