defmodule ForemanWeb.SessionGridTest do
  use ExUnit.Case, async: true
  alias ForemanWeb.SessionGrid

  test "coordinator first, then waiting, working, review, idle and ended; unassigned last" do
    rows = [
      item("main", "main_coordinator", nil, "Idle"),
      item("epic", "epic_coordinator", "main", "Working"),
      item("idle", "build", "epic", "Idle"),
      item("ended", "build", "epic", "Ended", true),
      item("work", "build", "epic", "Working"),
      item("review", "build", "epic", "In review"),
      item("wait", "build", "epic", "Waiting on you"),
      item("orphan", "build", nil, "Working")
    ]

    assert Enum.map(SessionGrid.build(rows), & &1.id) == [
             "group-main",
             "main",
             "group-epic",
             "epic",
             "wait",
             "work",
             "review",
             "idle",
             "ended",
             "group-unassigned",
             "orphan"
           ]
  end

  defp item(id, kind, parent, label, ended \\ false) do
    %{
      id: id,
      group: false,
      row: %{
        id: id,
        name: id,
        kind: kind,
        parent_id: parent,
        ended_at: if(ended, do: DateTime.utc_now())
      },
      view: %{label: label}
    }
  end
end
