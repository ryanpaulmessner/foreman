defmodule Foreman.TicketFile do
  @moduledoc "Shared ticket Markdown codec. String-keyed facts and an opaque Markdown body."
  @keys ~w(id title type status priority parent blocked_by related supersedes discovered_from labels created closed close_reason parked_reason parked)
  @lists ~w(blocked_by related supersedes labels)
  @types ~w(epic feature task bug decision chore)
  @statuses ~w(open in_progress closed deferred parked)

  def keys, do: @keys
  def types, do: @types
  def statuses, do: @statuses

  def valid_id?(id),
    do: is_binary(id) and Regex.match?(~r/\A[a-z][a-z0-9_]*-[a-z0-9]+(?:\.[1-9][0-9]*)*\z/, id)

  def parse(text) when is_binary(text) do
    with [_, yaml, body] <- Regex.run(~r/\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)(.*)\z/s, text),
         {:ok, pairs} <- YamlElixir.read_from_string(yaml, maps_as_keywords: true),
         true <- is_list(pairs) and Enum.all?(pairs, &match?({_, _}, &1)),
         true <- length(pairs) == map_size(Map.new(pairs)),
         facts = Map.put_new(Map.new(pairs), "supersedes", []),
         :ok <- validate(facts) do
      {:ok, %{facts: facts, body: String.trim_leading(body, "\n")}}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "malformed frontmatter (expected one mapping with unique keys)"}
    end
  end

  def validate(facts) do
    unknown = Map.keys(facts) -- @keys
    missing = (@keys -- ~w(supersedes parked_reason parked)) -- Map.keys(facts)

    cond do
      unknown != [] ->
        {:error, "unknown keys: #{inspect(unknown)}"}

      missing != [] ->
        {:error, "missing keys: #{Enum.join(missing, ", ")}"}

      not valid_id?(facts["id"]) ->
        {:error, "invalid id"}

      not text?(facts["title"]) ->
        {:error, "title must be nonempty text"}

      facts["type"] not in @types ->
        {:error, "invalid type"}

      facts["status"] not in @statuses ->
        {:error, "invalid status"}

      facts["priority"] not in 0..4 ->
        {:error, "priority must be 0..4"}

      not nullable_id?(facts["parent"]) ->
        {:error, "invalid parent"}

      not nullable_id?(facts["discovered_from"]) ->
        {:error, "invalid discovered_from"}

      not id_list?(facts["blocked_by"]) ->
        {:error, "blocked_by must be a list of ids"}

      not id_list?(facts["related"]) ->
        {:error, "related must be a list of ids"}

      not id_list?(Map.get(facts, "supersedes", [])) ->
        {:error, "supersedes must be a list of ids"}

      not (is_list(facts["labels"]) and Enum.all?(facts["labels"], &text?/1)) ->
        {:error, "labels must be a list of strings"}

      not date?(facts["created"]) ->
        {:error, "created must be an ISO date"}

      not (is_nil(facts["closed"]) or date?(facts["closed"])) ->
        {:error, "closed must be an ISO date or null"}

      not (is_nil(facts["close_reason"]) or text?(facts["close_reason"])) ->
        {:error, "close_reason must be text or null"}

      (facts["status"] == "parked" and not text?(facts["parked_reason"])) or
          not (is_nil(facts["parked_reason"]) or text?(facts["parked_reason"])) ->
        {:error, "parked_reason must be nonempty text when parked"}

      (facts["status"] == "parked" and not date?(facts["parked"])) or
          not (is_nil(facts["parked"]) or date?(facts["parked"])) ->
        {:error, "parked must be an ISO date when parked"}

      true ->
        :ok
    end
  end

  def print(%{facts: facts, body: body}) do
    facts = Map.put_new(facts, "supersedes", [])
    keys = Enum.reject(@keys, &(&1 in ~w(parked_reason parked) and is_nil(facts[&1])))
    header = Enum.map_join(keys, "\n", fn key -> "#{key}: #{scalar(key, facts[key])}" end)

    "---\n" <>
      header <>
      "\n---\n" <>
      if(String.trim(body) == "", do: "", else: "\n" <> String.trim_trailing(body, "\n") <> "\n")
  end

  defp scalar(key, values) when key in @lists, do: Jason.encode!(Enum.sort(values))
  defp scalar(_, nil), do: "null"

  defp scalar(key, value) when key in ~w(title close_reason parked_reason),
    do: Jason.encode!(value)

  defp scalar(_, value), do: to_string(value)
  defp text?(value), do: is_binary(value) and String.trim(value) != ""
  defp nullable_id?(value), do: is_nil(value) or valid_id?(value)
  defp id_list?(value), do: is_list(value) and Enum.all?(value, &valid_id?/1)
  defp date?(value) when is_binary(value), do: match?({:ok, _}, Date.from_iso8601(value))
  defp date?(_), do: false
end
