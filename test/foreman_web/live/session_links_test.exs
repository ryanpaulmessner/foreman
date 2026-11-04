defmodule ForemanWeb.SessionLinksTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Foreman.AgentSessionFixtures

  setup do
    {:ok, config} =
      Foreman.Config.parse_layers([{"defaults", File.read!("priv/foreman.defaults.toml")}])

    config =
      Map.put(config, "repos", [%{"key" => "sample", "path" => "/tmp/sample", "enabled" => true}])

    Foreman.Repo.insert_all("board_config", [
      %{
        id: 1,
        config: config,
        source: "/tmp/settings",
        discovered: [],
        loaded_at: DateTime.utc_now()
      }
    ])

    Foreman.Beads.Projection.replace(
      "sample",
      Enum.map_join(
        [
          %{id: "s", title: "Sessions epic", issue_type: "epic", status: "open"},
          %{
            id: "s-1",
            title: "Session ticket",
            issue_type: "task",
            status: "open",
            dependencies: [%{depends_on_id: "s", type: "parent-child"}]
          }
        ],
        "\n",
        &Jason.encode!/1
      )
    )

    :ok
  end

  test "card and drawer source variants link to their identity, not a name lookup", %{conn: conn} do
    parent = agent_session(name: "parent", kind: "main_coordinator", harness: "claude")
    live_row = agent_session(name: "build", parent_id: parent.id)

    dead =
      agent_session(name: "old-build", parent_id: parent.id)
      |> Foreman.AgentSessions.end_session()

    resumable =
      agent_session(name: "resumable", harness: "claude", conversation_id: Ecto.UUID.generate())
      |> Foreman.AgentSessions.end_session()

    main = Foreman.AgentSessions.end_session(parent)
    rows = [live_row, dead, resumable, main, nil]

    cards =
      for row <- rows do
        Foreman.Repo.insert!(%Foreman.Requests.Request{
          repo_key: "sample",
          bead_id: "s-1",
          kind: "decision",
          actor: "pi",
          state: "pending",
          agent_session_id: row && row.id,
          facts: %{"question" => "Keep this?", "options" => ["Keep"]}
        })
      end

    {:ok, view, _} = live(conn, "/needs-you")
    view |> element("#needs-you-badge") |> render_click()

    for {card, row} <- Enum.zip(cards, rows), prefix <- ["", "drawer-"] do
      selector = "##{prefix}card-source-#{card.id}"

      if row do
        assert has_element?(view, "#{selector} a[href='/sessions/#{row.id}']", row.name)

        if row.ended_at,
          do:
            assert(has_element?(view, "#{selector} button[disabled][title='The pane is closed']"))
      else
        assert has_element?(view, "#{selector} a[href='/sessions']", "Find the session")
      end

      refute has_element?(view, "#{selector} input")
      refute has_element?(view, "#{selector}", "tmux")
    end
  end

  test "ticket Sessions tab lists identity rows and no field dump", %{conn: conn} do
    row =
      agent_session(name: "ticket-build", project: "sample", ticket: "s-1")
      |> Foreman.AgentSessions.end_session()

    {:ok, view, _} = live(conn, "/?ticket=sample:s-1&tab=sessions")
    assert has_element?(view, "#ticket-sessions a[href='/sessions/#{row.id}']", "ticket-build")
    assert has_element?(view, "#ticket-session-#{row.id}-state-label", "Ended")
    assert has_element?(view, "#ticket-sessions", "build")
    refute has_element?(view, "#ticket-sessions", "workdir")
  end

  test "ticket Sessions tab has an empty state", %{conn: conn} do
    {:ok, view, _} = live(conn, "/?ticket=sample:s-1&tab=sessions")
    assert has_element?(view, "#ticket-sessions-empty", "No sessions for this ticket.")
  end

  test "epic session line opens the dead identity without an attach command", %{conn: conn} do
    row =
      agent_session(
        name: "epic-coordinator",
        kind: "epic_coordinator",
        project: "sample",
        ticket: "s"
      )
      |> Foreman.AgentSessions.end_session()

    agent_session(name: "newer-build-on-epic", project: "sample", ticket: "s")
    {:ok, view, _} = live(conn, "/epics/sample/s")
    assert has_element?(view, "#epic-session a[href='/sessions/#{row.id}']", row.name)
    assert has_element?(view, "#epic-session-state-label", "Ended")
    refute has_element?(view, "#epic-attach")
  end

  test "Initiatives strip has shared badge, name link and disabled dead Focus only", %{conn: conn} do
    row =
      agent_session(name: "coordinator", kind: "main_coordinator")
      |> Foreman.AgentSessions.end_session()

    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#coordinator a[href='/sessions/#{row.id}']", "coordinator")
    assert has_element?(view, "#coordinator-state-label", "Ended")
    assert has_element?(view, "#coordinator-focus[disabled]")
    refute has_element?(view, "#coordinator-relaunch")
    refute has_element?(view, "#coordinator-fresh")
  end
end
