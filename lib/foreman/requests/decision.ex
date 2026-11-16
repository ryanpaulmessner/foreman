defmodule Foreman.Requests.Decision do
  @moduledoc "A decision records an answer and can never enqueue external work."
  @behaviour Foreman.Requests.Kind
  @impl true
  def validate(facts, row) when is_map(facts) do
    with {:ok, docs} <- Foreman.CardText.docs(facts["docs"], row.repo_key) do
      validate_with_docs(facts, docs)
    end
  end

  def validate(_, _), do: {:error, :invalid_facts}

  @doc "Validates decision facts with document references already validated by CardText.docs/2."
  def validate_with_docs(facts, docs) do
    options = Map.get(facts, "options", [])
    recommendation = facts["recommendation"]

    if text?(facts["question"]) and is_list(options) and length(options) <= 30 and
         Enum.all?(options, &text?/1) and details?(facts["option_details"], options) and
         (is_nil(recommendation) or recommendation in options) and
         (is_nil(facts["text"]) or
            (is_binary(facts["text"]) and byte_size(facts["text"]) <= 20_000)) do
      with :ok <- clear?(Map.put(facts, "docs", docs), options) do
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

    missing =
      if Enum.any?([facts["question"], text], &image_reference?/1) or
           (facts["docs"] in [nil, []] and visual_judgment?(facts["question"])) do
        missing ++
          [
            "screenshots go on a review_ui card: foreman ask review_ui <ticket> --image <file-or-folder>"
          ]
      else
        missing
      end

    if missing == [], do: :ok, else: {:error, %{error: "card_unclear", missing: missing}}
  end

  defp image_reference?(text) do
    Regex.match?(~r/\S+\.(?:png|jpe?g|gif|webp)\b/i, text) or
      Regex.match?(~r/\.cache\/verify\/runs(?:\/|\b)/i, text)
  end

  defp visual_judgment?(question) do
    Regex.match?(~r/\b(?:screenshots?|mockups?)\b/i, question) and
      Regex.match?(~r/\blooks?\s+(?:right|good)\b/i, question)
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
