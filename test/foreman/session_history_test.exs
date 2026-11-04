defmodule Foreman.SessionHistoryTest do
  use Foreman.DataCase, async: false
  alias Foreman.{AgentSessions, Overlay, SessionHistory}

  test "a reused ticket excludes the next build's events and refused round starts" do
    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "s-1", title: "Ticket", issue_type: "task", status: "open"})
    )

    key = {"sample", "s-1"}

    {:ok, _} =
      Overlay.apply_event(key, {:dispatch, %{session: "first", harness: "pi", window: "%1"}})

    first = AgentSessions.live_by_name("first")
    {:error, _} = Overlay.apply_event(key, :request_changes)
    {:ok, _} = Overlay.apply_event(key, {:progress, %{body: "First only"}})
    {:ok, _} = Overlay.apply_event(key, :abandon)
    {:ok, _} = Overlay.apply_event(key, :revive)

    {:ok, _} =
      Overlay.apply_event(key, {:dispatch, %{session: "second", harness: "pi", window: "%2"}})

    {:ok, _} = Overlay.apply_event(key, {:progress, %{body: "Second only"}})
    rounds = SessionHistory.rounds(first)
    assert length(rounds) == 1
    text = rounds |> Enum.flat_map(& &1.events) |> Enum.map(& &1.text)
    assert "First only" in text
    refute "Second only" in text
  end
end
