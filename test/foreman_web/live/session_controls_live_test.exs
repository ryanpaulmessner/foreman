defmodule ForemanWeb.SessionControlsLiveTest do
  @moduledoc "The session page's live controls (spec Decisions 17-18) through the page's element ids."
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Foreman.AgentSessionFixtures
  alias Foreman.AgentSessions

  @idle_screen "───\n❯ \n───\n"

  # A stand-in tmux for the page: the tree check sees an empty server, the controls see
  # `pane`, Claude's prompt is idle and no client is attached. `fail` names commands that fail.
  defp tmux(pane, fail \\ []) do
    test = self()

    runner = fn "tmux", args, _ ->
      send(test, {:tmux, args})

      command =
        Enum.find(args, &(&1 in ~w(list-panes capture-pane kill-pane send-keys list-clients)))

      format = Enum.find(args, "", &String.contains?(&1, "pane_id"))

      cond do
        command in fail -> {"failed", 1}
        # The tree's listing (`Foreman.SessionTargets`): the server answers.
        format =~ "@build" or is_nil(pane) -> {"", 0}
        # The controls' pane check (`Foreman.SessionPane`).
        format =~ "pane_current_path" -> {Enum.join([pane, "w", "1", "1", "", ""], "\t"), 0}
        # Focus and the reply path (`Foreman.RequestSource`).
        command == "list-panes" -> {Enum.join([pane, "@1", "s", "w", "1"], "\t"), 0}
        command == "capture-pane" -> {@idle_screen, 0}
        true -> {"", 0}
      end
    end

    Application.put_env(:foreman, :session_controls_tmux,
      runner: runner,
      key_delay: 0,
      platform: :none
    )

    on_exit(fn ->
      Application.put_env(:foreman, :session_controls_tmux, runner: &Foreman.TestTmux.no_panes/3)
    end)
  end

  defp in_state(attrs, events) do
    Enum.reduce(events, agent_session(attrs), fn event, row ->
      {:ok, row, _} = AgentSessions.fire(row, event)
      row
    end)
  end

  defp card(row, facts) do
    Foreman.Repo.insert!(%Foreman.Requests.Request{
      repo_key: "sample",
      bead_id: "s-1",
      kind: "session_waiting",
      actor: "pi",
      state: "pending",
      agent_session_id: row.id,
      facts: facts
    })
  end

  defp open(conn, row) do
    {:ok, view, _} = live(conn, "/sessions/#{row.id}")
    view
  end

  test "a working build: Focus and Stop; off controls in one line; no Park", %{conn: conn} do
    view = open(conn, in_state(%{name: "page-build", pane_id: "%5"}, [:output_changed]))

    assert has_element?(
             view,
             "#session-controls #session-control-focus[phx-disable-with='Focusing…']"
           )

    assert has_element?(view, "#session-controls #session-stop")
    refute has_element?(view, "#session-control-park")
    refute has_element?(view, "#session-message-form")

    assert view |> element("#session-unavailable") |> render() =~
             "Answer on the card (No card is open.) · Continue (Only after a usage limit.) · " <>
               "Send message (The agent is working. A message now interrupts it.)"
  end

  test "a usage limit puts Continue in the next-step panel; Answer moves to the controls", %{
    conn: conn
  } do
    row = in_state(%{pane_id: "%5"}, [:output_changed])
    card(row, %{"reason" => "usage_limit", "provider" => "OpenAI"})
    {:ok, row, _} = AgentSessions.fire(row, :usage_limit)
    view = open(conn, row)

    assert has_element?(
             view,
             "#session-next-step #session-control-continue[phx-disable-with='Continuing…']"
           )

    assert has_element?(view, "#session-controls #session-control-answer")

    assert has_element?(
             view,
             "#session-unavailable",
             "Send message (Use Continue at a usage limit.)"
           )
  end

  test "a permission prompt puts Focus terminal in the panel", %{conn: conn} do
    view = open(conn, in_state(%{pane_id: "%5"}, [:permission_prompt]))
    assert has_element?(view, "#session-next-step #session-control-focus")
    refute has_element?(view, "#session-controls #session-control-focus")
  end

  test "an idle epic coordinator: Park and the message box", %{conn: conn} do
    row =
      in_state(%{name: "epic", kind: "epic_coordinator", harness: "claude", pane_id: "%5"}, [
        :output_changed,
        :quiet
      ])

    view = open(conn, row)
    assert has_element?(view, "#session-control-park[phx-disable-with='Parking…']")
    assert has_element?(view, "#session-message-form label", "Message to epic")
    assert has_element?(view, "#session-message-send[phx-disable-with='Sending…']")
  end

  test "the main coordinator says why it does not park", %{conn: conn} do
    row =
      in_state(
        %{name: "coordinator", kind: "main_coordinator", harness: "claude", pane_id: "%5"},
        []
      )

    view = open(conn, row)
    refute has_element?(view, "#session-control-park")

    assert has_element?(
             view,
             "#session-unavailable",
             "Park (The main coordinator does not park.)"
           )
  end

  test "a dead session shows no live control", %{conn: conn} do
    row = %{name: "gone"} |> agent_session() |> AgentSessions.end_session()
    view = open(conn, row)
    refute has_element?(view, "#session-controls")

    assert has_element?(
             view,
             "#session-unavailable",
             "Continue, Focus terminal, Send message and Stop (The pane is closed.)"
           )
  end

  describe "Stop" do
    test "opens an in-page confirm with the focus on Keep it running", %{conn: conn} do
      row =
        in_state(
          %{name: "page-build", pane_id: "%5", workdir: "/w/page-build", branch: "feat/x"},
          [:output_changed]
        )

      view = open(conn, row)
      view |> element("#session-stop") |> render_click()
      assert has_element?(view, "#session-stop-confirm[role=alertdialog]", "Stop page-build?")

      assert has_element?(view, "#session-stop-confirm .font-mono", "/w/page-build")
      assert has_element?(view, "#session-stop-confirm .font-mono", "feat/x")
      assert has_element?(view, "#session-stop-confirm", "stay.")

      assert has_element?(view, "#session-stop-keep[phx-mounted]")
      assert has_element?(view, "#session-stop-confirm-yes[phx-disable-with='Stopping…']")
      view |> element("#session-stop-keep") |> render_click()
      refute has_element?(view, "#session-stop-confirm")
      assert %{ended_at: nil} = AgentSessions.get(row.id)
    end

    test "a coordinator's confirm says its builds keep running", %{conn: conn} do
      row =
        in_state(%{name: "epic", kind: "epic_coordinator", harness: "claude", pane_id: "%5"}, [])

      view = open(conn, row)
      view |> element("#session-stop") |> render_click()
      assert has_element?(view, "#session-stop-confirm", "Its builds keep running.")
    end

    test "Stop session saves, closes the pane and says so", %{conn: conn} do
      tmux("%5")
      row = in_state(%{name: "page-build", pane_id: "%5"}, [:output_changed])
      view = open(conn, row)
      view |> element("#session-stop") |> render_click()
      view |> element("#session-stop-confirm-yes") |> render_click()

      assert has_element?(
               view,
               "#session-result",
               "Stopped page-build. The worktree and branch stay."
             )

      refute has_element?(view, "#session-stop-confirm")
      assert %{state: "ended"} = AgentSessions.get(row.id)
      assert %{reason: "stop"} = Foreman.SessionCaptures.get(row.id)
      assert has_element?(view, "#session-unavailable", "(The pane is closed.)")
    end

    test "a failure says nothing changed", %{conn: conn} do
      tmux(nil)
      row = in_state(%{name: "page-build", pane_id: "%5"}, [:output_changed])
      view = open(conn, row)
      view |> element("#session-stop") |> render_click()
      view |> element("#session-stop-confirm-yes") |> render_click()

      assert has_element?(
               view,
               "#session-result[role=alert]",
               "Could not stop page-build: the pane is closed. Nothing changed."
             )

      assert %{ended_at: nil} = AgentSessions.get(row.id)
    end
  end

  test "Park parks a coordinator", %{conn: conn} do
    tmux("%5")

    row =
      in_state(%{name: "epic", kind: "epic_coordinator", harness: "claude", pane_id: "%5"}, [
        :output_changed
      ])

    view = open(conn, row)
    view |> element("#session-control-park") |> render_click()
    assert has_element?(view, "#session-result", "Parked epic. Its builds keep running.")
    assert %{state: "parked"} = AgentSessions.get(row.id)
  end

  test "Continue's result stays until the session changes", %{conn: conn} do
    tmux("%5")
    row = in_state(%{name: "page-build", pane_id: "%5"}, [:usage_limit])
    view = open(conn, row)
    view |> element("#session-control-continue") |> render_click()
    assert has_element?(view, "#session-result", ~s(Sent "continue" to page-build.))
    send(view.pid, {:notification, :foreman_events, %{kind: "sessions_changed"}})
    assert has_element?(view, "#session-result")

    AgentSessions.fire(row, :output_changed)
    send(view.pid, {:notification, :foreman_events, %{kind: "sessions_changed"}})
    refute has_element?(view, "#session-result")
  end

  test "Focus with no attached terminal points at the attach command", %{conn: conn} do
    tmux("%5")
    view = open(conn, in_state(%{name: "page-build", pane_id: "%5"}, [:output_changed]))
    view |> element("#session-control-focus") |> render_click()

    assert has_element?(
             view,
             "#session-result",
             "No terminal is attached. Copy the attach command from Details."
           )
  end

  test "Send message types the line, and an empty one asks for text", %{conn: conn} do
    tmux("%5")

    row =
      in_state(%{name: "epic", kind: "epic_coordinator", harness: "claude", pane_id: "%5"}, [
        :output_changed,
        :quiet
      ])

    view = open(conn, row)

    view |> form("#session-message-form", message: %{text: " "}) |> render_submit()
    assert has_element?(view, "#session-message-form", "Enter a message.")

    view |> form("#session-message-form", message: %{text: "Check the build"}) |> render_submit()
    assert has_element?(view, "#session-result", "Sent to epic.")
    refute has_element?(view, "#session-message-form input[value='Check the build']")
    assert_received {:tmux, [_, _, _, "send-keys", "-t", "%5", "-l", "--", "Check the build"]}
  end

  test "tmux does not answer: the panel says so and Try again now reads again", %{conn: conn} do
    tmux("%5", ["list-panes"])
    view = open(conn, in_state(%{name: "page-build", pane_id: "%5"}, [:output_changed]))

    assert has_element?(view, "#session-next-step", "The board cannot reach tmux.")

    assert has_element?(
             view,
             "#session-next-step #session-control-retry[phx-disable-with='Trying…']"
           )

    assert has_element?(view, "#session-state-second", "not checked since")
    refute has_element?(view, "#session-stop")

    assert has_element?(
             view,
             "#session-unavailable",
             "Continue, Focus terminal, Send message and Stop (tmux does not answer.)"
           )

    view |> element("#session-control-retry") |> render_click()
    assert has_element?(view, "#session-result", "tmux still does not answer.")

    tmux("%5")
    view |> element("#session-control-retry") |> render_click()
    refute has_element?(view, "#session-next-step", "The board cannot reach tmux.")
    refute has_element?(view, "#session-result")
    assert has_element?(view, "#session-stop")
  end
end
