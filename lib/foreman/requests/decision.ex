defmodule Foreman.Requests.Decision do
  @moduledoc "A decision records an answer and can never enqueue external work."
  @behaviour Foreman.Requests.Kind
  @impl true
  def validate(facts, row) when is_map(facts) do
    options = Map.get(facts, "options", [])
    recommendation = facts["recommendation"]

    if text?(facts["question"]) and is_list(options) and length(options) <= 30 and
         Enum.all?(options, &text?/1) and details?(facts["option_details"], options) and
         (is_nil(recommendation) or recommendation in options) and
         (is_nil(facts["text"]) or
            (is_binary(facts["text"]) and byte_size(facts["text"]) <= 20_000)) do
      # --doc paths must name Markdown files in a configured repo; stored as {repo, path}.
      with :ok <- clear?(facts, options),
           {:ok, docs} <- Foreman.CardText.docs(facts["docs"], row.repo_key) do
        facts =
          facts
          |> Map.put("options", Enum.uniq(options))
          |> Map.take(~w(question options recommendation text option_details))

        {:ok, if(docs == [], do: facts, else: Map.put(facts, "docs", docs))}
      end
    else
      {:error, :invalid_facts}
    end
  end

  def validate(_, _), do: {:error, :invalid_facts}
  @impl true
  def enqueue(_), do: {:error, :decision_not_executable}

  defp clear?(facts, options) do
    text = facts["text"] || ""

    labels =
      Enum.reject(["What", "Part of", "Why now"], fn label ->
        Regex.match?(
          Regex.compile!("(?:^|\\n)\\s*(?:\\*\\*)?" <> label <> "\\s*:(?:\\*\\*)?", "i"),
          text
        )
      end)

    details = facts["option_details"] || %{}

    missing =
      labels ++ for option <- options, not text?(details[option]), do: "option detail: " <> option

    if missing == [], do: :ok, else: {:error, %{error: "card_unclear", missing: missing}}
  end

  defp details?(nil, _), do: true

  defp details?(details, options) when is_map(details),
    do:
      Enum.all?(details, fn {option, text} ->
        option in options and is_binary(text) and byte_size(text) <= 20_000
      end)

  defp details?(_, _), do: false

  def text?(value),
    do: is_binary(value) and String.trim(value) != "" and byte_size(value) <= 20_000
end
