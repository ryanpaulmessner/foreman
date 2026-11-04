defmodule ForemanWeb.SessionLiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Foreman.AgentSessionFixtures

  test "working session opens Recent output and Details keeps the attach command", %{conn: conn} do
    row = agent_session(name: "page-build", pane_id: "%8", branch: "feat/session")
    {:ok, view, _} = live(conn, "/sessions/#{row.id}")
    assert has_element?(view, "#session-heading", "page-build")
    assert has_element?(view, "#session-state-label", "Working")
    assert has_element?(view, "#session-next-step", "Working on round 1.")
    assert has_element?(view, "#session-state-second", "Round 1")
    assert has_element?(view, "#session-output")
    refute has_element?(view, "#session-attach")
    view |> element("#session-tab-details") |> render_click()
    assert has_element?(view, "#session-attach[phx-hook='CopyField']")
    assert has_element?(view, "#session-details", "feat/session")
    assert has_element?(view, "#session-details time[title]")
  end

  for {event, label, panel, tab} <- [
        {:quiet, "Idle", "Idle.", "output"},
        {:asked, "Waiting on you", "It asked you a question.", "timeline"},
        {:permission_prompt, "Waiting on you",
         "It waits for a permission answer in the terminal.", "timeline"},
        {:usage_limit, "Waiting on you", "Stopped at the provider usage limit.", "timeline"},
        {:exited, "Ended", "This build cannot resume: No Pi session id was recorded at launch.",
         "timeline"},
        {:park, "Parked", "Its builds keep running.", "timeline"}
      ] do
    test "panel for #{event}", %{conn: conn} do
      row =
        agent_session(kind: if(unquote(event) == :park, do: "epic_coordinator", else: "build"))

      {:ok, row, _} = Foreman.AgentSessions.fire(row, :output_changed)
      {:ok, row, _} = Foreman.AgentSessions.fire(row, unquote(event))
      {:ok, view, _} = live(conn, "/sessions/#{row.id}")
      assert has_element?(view, "#session-state-label", unquote(label))
      assert has_element?(view, "#session-next-step", unquote(panel))
      assert has_element?(view, "#session-tab-#{unquote(tab)}[aria-current=page]")
      assert has_element?(view, "#session-unavailable", "Not available now:")
    end
  end

  test "ended resumable session does not offer live controls", %{conn: conn} do
    row =
      agent_session(harness: "claude", conversation_id: Ecto.UUID.generate())
      |> Foreman.AgentSessions.end_session()

    {:ok, view, _} = live(conn, "/sessions/#{row.id}")
    assert has_element?(view, "#session-next-step", "Ended")
    refute has_element?(view, "#session-next-step", "cannot resume")
    assert has_element?(view, "#session-unavailable", "The pane is closed.")
    refute has_element?(view, "#session-next-step button")
  end

  test "open card on a dead session stays waiting without promising future answer routing", %{
    conn: conn
  } do
    row = agent_session() |> Foreman.AgentSessions.end_session()

    card =
      Foreman.Repo.insert!(%Foreman.Requests.Request{
        repo_key: "sample",
        bead_id: "s-1",
        kind: "decision",
        actor: "pi",
        state: "pending",
        agent_session_id: row.id,
        facts: %{"question" => "Keep the rounds?"}
      })

    {:ok, view, _} = live(conn, "/sessions/#{row.id}")
    assert has_element?(view, "#session-state-label", "Waiting on you")
    assert has_element?(view, "#session-next-step", "Its question is still open.")
    assert has_element?(view, "#session-state-second", "cannot resume")
    assert has_element?(view, "#session-answer[href='/needs-you#request-#{card.id}']")
    refute has_element?(view, "#session-next-step", "resumes the session first")
  end

  test "dead coordinator without a conversation id explains why", %{conn: conn} do
    row =
      agent_session(kind: "main_coordinator", harness: "claude")
      |> Foreman.AgentSessions.end_session()

    {:ok, view, _} = live(conn, "/sessions/#{row.id}")
    assert has_element?(view, "#session-next-step", "The board has no conversation id for it.")
  end

  test "timeline groups two review rounds with the current one open", %{conn: conn} do
    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "s-1", title: "A session ticket", issue_type: "task", status: "open"})
    )

    key = {"sample", "s-1"}
    parent = agent_session(name: "reviewer", kind: "epic_coordinator")

    assert {:ok, _} =
             Foreman.Overlay.apply_event(
               key,
               {:dispatch,
                %{
                  "session" => "round-build",
                  "coordinator" => parent.name,
                  "window" => "%3",
                  "harness" => "pi"
                }}
             )

    row = Foreman.AgentSessions.live_by_name("round-build")
    assert {:ok, _} = Foreman.Overlay.apply_event(key, {:progress, %{"body" => "First change"}})
    assert {:ok, _} = Foreman.Overlay.apply_event(key, {:report, %{"path" => "reports/one.md"}})
    assert {:ok, _} = Foreman.Overlay.apply_event(key, :review)

    assert {:ok, _} =
             Foreman.Overlay.apply_event(key, {:request_changes, %{"body" => "Fix the grouping"}})

    assert {:ok, _} = Foreman.Overlay.apply_event(key, {:progress, %{"body" => "Second change"}})
    assert {:ok, _} = Foreman.Overlay.apply_event(key, {:report, %{"path" => "reports/two.md"}})
    {:ok, row, _} = Foreman.AgentSessions.fire(row, :output_changed)
    {:ok, row, _} = Foreman.AgentSessions.fire(row, :quiet)
    {:ok, view, _} = live(conn, "/sessions/#{row.id}?tab=timeline")
    assert has_element?(view, "#session-heading", "A session ticket")
    assert has_element?(view, "#session-next-step", "reviewer reviews round 2.")
    assert has_element?(view, "#session-state-second", "Round 2 report · reviewer reviews")
    assert has_element?(view, "#session-round-1-toggle[aria-expanded=false]")
    assert has_element?(view, "#session-round-2-toggle[aria-expanded=true]")
    assert has_element?(view, "#session-round-2", "Second change")
    refute has_element?(view, "#session-round-1-events")
    view |> element("#session-round-1-toggle") |> render_click()
    assert has_element?(view, "#session-round-1-events", "First change")
    assert has_element?(view, "#session-round-1-events", "reports/one.md")
  end

  test "a live page switches to the dead view on a session notification", %{conn: conn} do
    row = agent_session()
    {:ok, view, _} = live(conn, "/sessions/#{row.id}")
    Foreman.AgentSessions.end_session(row)
    send(view.pid, {:notification, :foreman_events, %{kind: "sessions_changed"}})
    assert has_element?(view, "#session-state-label", "Ended")
    assert has_element?(view, "#session-tab-timeline[aria-current=page]")
    assert has_element?(view, "#session-no-events", "No events yet.")
    refute has_element?(view, "#session-live-line")
  end

  test "an explicit tab survives lifecycle updates", %{conn: conn} do
    row = agent_session()
    {:ok, view, _} = live(conn, "/sessions/#{row.id}?tab=details")
    Foreman.AgentSessions.end_session(row)
    send(view.pid, {:notification, :foreman_events, %{kind: "sessions_changed"}})
    assert has_element?(view, "#session-details")
    assert has_element?(view, "#session-state-label", "Ended")
  end

  test "unknown id shows the breadcrumb and plain text", %{conn: conn} do
    {:ok, view, _} = live(conn, "/sessions/not-an-id")
    assert has_element?(view, "#session-breadcrumb")
    assert has_element?(view, "#session-unknown", "The board has no session with this id.")
    refute has_element?(view, "#session-next-step")
  end
end
