defmodule Foreman.SessionFallback do
  @moduledoc "The configured alternative at a usage limit (Decision 19)."
  def model(%{state: "waiting.usage_limit", harness: "pi", kind: "build"} = row),
    do: configured(row.model)

  def model(%{state: "waiting.usage_limit", harness: "claude", kind: kind} = row)
      when kind in ~w(main_coordinator epic_coordinator) do
    family = family(row.model)
    target = configured(row.model)

    limits =
      Foreman.AgentSessions.open_cards(row.id)
      |> Enum.filter(&(&1.kind == "session_waiting" and &1.facts["reason"] == "usage_limit"))

    if family in ~w(opus sonnet) and family(target) in ~w(opus sonnet) and
         family(target) != family and limits != [] and
         Enum.all?(limits, &(&1.facts["limit_family"] == family)),
       do: target
  end

  def model(_row), do: nil

  def limit_family(text) when is_binary(text) do
    if not Regex.match?(~r/\b(?:session|weekly|spend|monthly) limit\b|shared budget/i, text) do
      case Regex.run(~r/\bhit your (Opus|Sonnet) limit\b/i, text, capture: :all_but_first) do
        [family] -> String.downcase(family)
        _ -> nil
      end
    end
  end

  defp family(model) when is_binary(model) do
    case Regex.run(~r/\A(?:anthropic\/)?claude-(opus|sonnet)-/, model, capture: :all_but_first) do
      [family] -> family
      _ -> nil
    end
  end

  defp family(_), do: nil

  defp configured(model) do
    snapshot = Foreman.RuntimeState.config()
    config = if snapshot, do: snapshot.config, else: %{}

    Enum.find_value(Foreman.Config.model_fallbacks(config), fn pair ->
      if pair["from"] == model, do: pair["to"]
    end)
  end
end
