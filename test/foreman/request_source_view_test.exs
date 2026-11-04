defmodule Foreman.RequestSourceViewTest do
  @moduledoc "The card's Asked by row data: one test per source row variant (spec Decision 14)."
  use Foreman.DataCase, async: false
  alias Foreman.RequestSource

  import Foreman.AgentSessionFixtures

  defp request(row), do: %{session: row && row.name, actor: "pi", agent_session_id: row && row.id}

  test "live build: its name, build under its coordinator, live, Focus on" do
    coordinator =
      agent_session(name: "foreman-board", kind: "main_coordinator", harness: "claude")

    build = agent_session(name: "qc-compact-card", parent_id: coordinator.id, pane_id: "%7")

    assert %{
             state: :live,
             name: "qc-compact-card",
             role: "build under foreman-board",
             ended_at: nil,
             focus: true,
             link: link,
             receiver: nil,
             source: %{target: "%7"}
           } = RequestSource.view(request(build))

    assert link == "/sessions/#{build.id}"
  end

  test "coordinators use the Sessions role words" do
    main = agent_session(name: "foreman-board", kind: "main_coordinator", harness: "claude")
    epic = agent_session(name: "sessions-epic", kind: "epic_coordinator", parent_id: main.id)
    loose = agent_session(name: "loose-build")

    assert RequestSource.view(request(main)).role == "main coordinator"
    assert RequestSource.view(request(epic)).role == "epic coordinator"
    assert RequestSource.view(request(loose)).role == "build"

    for row <- [main, epic, loose],
        do: assert(RequestSource.view(request(row)).link == "/sessions/#{row.id}")
  end

  test "ended: the end time, Focus off, and no receiver or resume until those ship" do
    row = agent_session(name: "sb-notify", pane_id: "%9") |> Foreman.AgentSessions.end_session()

    assert %{
             state: :ended,
             name: "sb-notify",
             role: "build",
             ended_at: %DateTime{} = ended_at,
             focus: false,
             receiver: nil,
             resumes: false
           } = RequestSource.view(request(row))

    assert ended_at == row.ended_at
    assert RequestSource.view(request(row)).link == "/sessions/#{row.id}"
  end

  test "main coordinator ended: its role and end time" do
    row =
      agent_session(name: "foreman-board", kind: "main_coordinator", harness: "claude")
      |> Foreman.AgentSessions.end_session()

    assert %{state: :ended, role: "main coordinator", focus: false} =
             RequestSource.view(request(row))

    assert RequestSource.view(request(row)).link == "/sessions/#{row.id}"
  end

  test "unknown: no row for the card" do
    assert %{state: :unknown, name: nil, role: nil, focus: false, link: nil, source: nil} =
             RequestSource.view(request(nil))

    assert %{state: :unknown} =
             RequestSource.view(%{session: "gone", agent_session_id: Ecto.UUID.generate()})
  end
end
