defmodule ForemanWeb.SessionStateTest do
  @moduledoc "Table test for the one session state function (spec Decision 9, R1, R2)."
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias ForemanWeb.SessionState

  @now ~U[2026-11-04 12:00:00Z]
  @five_ago ~U[2026-11-04 11:55:00Z]
  @hour_ago ~U[2026-11-04 11:00:00Z]

  defp facts(attrs), do: Map.merge(%{kind: "build", open_cards: 0, state_at: @five_ago}, attrs)
  defp view(attrs), do: SessionState.view(facts(attrs), @now)

  @waiting %{label: "Waiting on you", color: "primary", variant: "solid", icon: "hero-inbox"}

  # {case, facts, label row, second line, time named by the second line}
  @table [
    {"question with cards", %{state: "waiting.question", open_cards: 2, card_at: @hour_ago},
     @waiting, "2 cards · 1 h ago", @hour_ago},
    {"one card", %{state: "waiting.question", open_cards: 1, card_at: @five_ago}, @waiting,
     "1 card · 5 min ago", @five_ago},
    {"permission prompt", %{state: "waiting.permission", open_cards: 1}, @waiting,
     "Permission prompt · 5 min ago", @five_ago},
    {"usage limit, reset text from the hook",
     %{state: "waiting.usage_limit", open_cards: 1, reset_at: "3pm (Europe/London)"}, @waiting,
     "Usage limit · resets 3pm (Europe/London)", nil},
    {"usage limit, reset time",
     %{state: "waiting.usage_limit", reset_at: ~U[2026-11-04 14:00:00Z]}, @waiting,
     "Usage limit · resets in 2 h", ~U[2026-11-04 14:00:00Z]},
    {"R2: open card on an ended session",
     %{state: "ended", open_cards: 1, card_at: @hour_ago, ended_at: @five_ago}, @waiting,
     "ended 5 min ago", @five_ago},
    {"R2: open card on a working session", %{state: "working", open_cards: 1, card_at: @five_ago},
     @waiting, "1 card · 5 min ago", @five_ago},
    {"in review: idle build, ticket reported", %{state: "idle", stage: :reported},
     %{label: "In review", color: "warning", variant: "soft", icon: nil}, "for 5 min", @five_ago},
    {"in review: idle build, ticket in_review", %{state: "idle", stage: :in_review},
     %{label: "In review", color: "warning", variant: "soft", icon: nil}, "for 5 min", @five_ago},
    {"working", %{state: "working"},
     %{label: "Working", color: "info", variant: "soft", icon: nil}, nil, nil},
    {"starting", %{state: "starting"},
     %{label: "Working", color: "info", variant: "soft", icon: nil}, nil, nil},
    {"idle", %{state: "idle", stage: :building},
     %{label: "Idle", color: "neutral", variant: "soft", icon: nil}, "for 5 min", @five_ago},
    {"idle coordinator, review stage does not apply",
     %{state: "idle", kind: "epic_coordinator", stage: :reported},
     %{label: "Idle", color: "neutral", variant: "soft", icon: nil}, "for 5 min", @five_ago},
    {"parked", %{state: "parked", kind: "epic_coordinator", ended_at: @hour_ago},
     %{label: "Parked", color: "neutral", variant: "outline", icon: nil}, "parked 1 h ago",
     @hour_ago},
    {"ended", %{state: "ended", ended_at: @hour_ago},
     %{label: "Ended", color: "neutral", variant: "outline", icon: nil}, "ended 1 h ago",
     @hour_ago},
    {"R8: live build whose coordinator ended", %{state: "working", parent_ended_at: @hour_ago},
     %{label: "Working", color: "info", variant: "soft", icon: nil}, "Parent ended 1 h ago",
     @hour_ago}
  ]

  for {name, facts, badge, second, at} <- @table do
    test "#{name}" do
      assert view(unquote(Macro.escape(facts))) ==
               Map.merge(unquote(Macro.escape(badge)), %{
                 second: unquote(second),
                 at: unquote(Macro.escape(at))
               })
    end
  end

  test "idle for under a minute reads as such" do
    assert %{second: "for under 1 min"} =
             SessionState.view(facts(%{state: "idle", state_at: @now}), @now)
  end

  test "R1: every state, card count and stage gives exactly one label from the table" do
    labels = ["Waiting on you", "In review", "Working", "Idle", "Parked", "Ended"]

    for state <- Foreman.SessionLifecycle.stored(),
        cards <- [0, 1, 3],
        stage <- [nil, :building, :reported, :in_review, :committed],
        kind <- Foreman.AgentSession.kinds() do
      view =
        view(%{state: state, open_cards: cards, stage: stage, kind: kind, ended_at: @hour_ago})

      assert view.label in labels
      assert is_binary(view.color) and is_binary(view.variant)
      if cards > 0, do: assert(view.label == "Waiting on you")
    end
  end

  test "the badge component shows the label, icon and second line with the full time on hover" do
    html =
      render_component(&SessionState.badge/1,
        id: "s1",
        view: view(%{state: "waiting.question", open_cards: 1, card_at: @five_ago})
      )

    doc = LazyHTML.from_fragment(html)
    assert LazyHTML.text(LazyHTML.query(doc, "#s1-label")) =~ "Waiting on you"

    assert LazyHTML.attribute(LazyHTML.query(doc, "#s1-second"), "title") == [
             "2026-11-04T11:55:00Z"
           ]

    assert LazyHTML.text(LazyHTML.query(doc, "#s1-second")) =~ "1 card · "
  end
end
