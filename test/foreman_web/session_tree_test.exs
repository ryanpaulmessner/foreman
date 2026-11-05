defmodule ForemanWeb.SessionTreeTest do
  use ExUnit.Case, async: true
  alias ForemanWeb.SessionTree

  test "main, epic and builds form an outline; orphans come last" do
    tree =
      SessionTree.build([
        entry("orphan"),
        entry("build", "epic"),
        entry("epic", "main", "epic_coordinator"),
        entry("main", nil, "main_coordinator")
      ])

    assert Enum.map(tree.rows, &{&1.id, &1.depth}) == [
             {"main", 0},
             {"epic", 1},
             {"build", 2},
             {"unassigned", 0},
             {"orphan", 1}
           ]
  end

  test "ended rows require Show ended and expire after seven days; open cards and live descendants retain parents" do
    now = ~U[2026-11-05 12:00:00Z]
    recent = dead(entry("recent"), DateTime.add(now, -60))
    old = dead(entry("old"), DateTime.add(now, -8 * 86400))
    parent = dead(entry("parent", nil, "epic_coordinator"), DateTime.add(now, -9 * 86400))
    waiting = put_in(old.facts.open_cards, 1)
    entries = [recent, parent, entry("child", "parent"), waiting]
    tree = SessionTree.build(entries, now: now)
    assert Enum.map(tree.rows, & &1.id) == ["unassigned", "old", "parent", "child"]
    assert tree.ended_count == 1

    assert Enum.map(SessionTree.build(entries, now: now, show_ended: true).rows, & &1.id) == [
             "unassigned",
             "old",
             "parent",
             "child",
             "recent"
           ]
  end

  test "waiting strip includes dead questions and permission and usage waits" do
    question =
      entry("question") |> put_in([:facts, :open_cards], 2) |> Map.put(:cards, [%{id: "card-1"}])

    permission =
      entry("permission")
      |> put_in([:facts, :state], "waiting.permission")
      |> put_in([:facts, :open_cards], 1)
      |> Map.put(:cards, [%{id: "permission-card"}])

    usage = put_in(entry("usage").facts.state, "waiting.usage_limit")
    ended = dead(question, ~U[2026-11-01 12:00:00Z])
    tree = SessionTree.build([permission, usage, ended])

    assert Enum.map(tree.waiting, & &1.action) == [
             "Permission prompt · open the terminal",
             "Answer 2 cards · session ended",
             "Usage limit · press Continue"
           ]

    assert Enum.find(tree.waiting, &(&1.id == "permission")).href == "/sessions/permission"
    assert Enum.find(tree.waiting, &(&1.id == "question")).href == "/needs-you?card=card-1"
  end

  defp dead(entry, at) do
    %{
      entry
      | row: %{entry.row | state: "ended", ended_at: at},
        facts: Map.merge(entry.facts, %{state: "ended", ended_at: at})
    }
  end

  defp entry(id, parent \\ nil, kind \\ "build") do
    %{
      row: %Foreman.AgentSession{
        id: id,
        name: id,
        parent_id: parent,
        kind: kind,
        state: "working"
      },
      facts: %{state: "working", kind: kind, open_cards: 0},
      cards: []
    }
  end
end
