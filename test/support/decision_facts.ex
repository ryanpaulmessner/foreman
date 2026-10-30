defmodule Foreman.DecisionFacts do
  @moduledoc "Valid decision context for tests that exercise lifecycle or rendering rather than lint."
  def valid(facts) do
    details = Map.new(Map.get(facts, "options", []), &{&1, "Use #{&1}"})

    facts
    |> Map.put(
      "text",
      "What: Layout\nPart of: Test ticket\nWhy now: Review\n\n" <> (facts["text"] || "")
    )
    |> Map.put_new("option_details", details)
  end
end
