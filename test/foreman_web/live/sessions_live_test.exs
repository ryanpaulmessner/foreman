defmodule ForemanWeb.SessionsLiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Foreman.AgentSessionFixtures
  import Mimic
  setup :set_mimic_global

  setup do
    Application.put_env(:foreman, :session_tree_tmux, runner: fn _, _, _ -> {"", 0} end)
    on_exit(fn -> Application.delete_env(:foreman, :session_tree_tmux) end)
    :ok
  end

  test "Start main coordinator starts fresh, then resumes the last conversation", %{conn: conn} do
    expect(Foreman.SessionTmux, :launch, fn _, "/orient", _ -> {:ok, "@1"} end)
    {:ok, view, _} = live(conn, "/sessions")
    view |> element("#start-main-coordinator") |> render_click()
    main = Foreman.AgentSessions.main_coordinator()
    assert has_element?(view, "#session-link-#{main.id}")

    Foreman.Sessions.coordinator()
    |> Ecto.Changeset.change(state: :ended, window: nil)
    |> Foreman.Repo.update!()

    Foreman.AgentSessions.end_session(main)
    send(view.pid, {:notification, :foreman_events, "{}"})

    expect(Foreman.SessionTmux, :resume, fn session, _ ->
      assert session.session_id == main.id
      {:ok, "@2"}
    end)

    view |> element("#start-main-coordinator") |> render_click()
    assert has_element?(view, "#session-link-#{main.id}")
  end

  test "empty states and ended filter", %{conn: conn} do
    {:ok, view, _} = live(conn, "/sessions")
    assert has_element?(view, "#sessions-empty", "No sessions are running")
    assert has_element?(view, "#start-main-coordinator[phx-disable-with='Starting…']")
    view |> element("#show-ended-form") |> render_change(%{"ended" => "true"})
    assert has_element?(view, "#sessions-empty", "No sessions ended in the last 7 days.")
  end

  test "loading and connection-lost markup is available before connection", %{conn: conn} do
    html = conn |> get("/sessions") |> html_response(200) |> LazyHTML.from_document()
    assert LazyHTML.query(html, "#sessions-loading") |> LazyHTML.text() =~ "Loading sessions…"

    assert LazyHTML.query(html, "#sessions-disconnected") |> LazyHTML.text() =~
             "Not connected to the board. Trying again…"

    assert LazyHTML.query(html, "#sessions-live-line") |> LazyHTML.text() =~ "Connecting…"
  end

  test "tmux failure leaves rows readable and disables focus until retry", %{conn: conn} do
    row = agent_session()
    Application.put_env(:foreman, :session_tree_tmux, runner: fn _, _, _ -> {"denied", 1} end)
    {:ok, view, _} = live(conn, "/sessions")

    assert has_element?(
             view,
             "#sessions-tmux-error",
             "Cannot read tmux. States can be out of date."
           )

    assert has_element?(view, "#focus-#{row.id}[disabled][title='tmux does not answer']")
    assert has_element?(view, "#session-link-#{row.id}")
    Application.put_env(:foreman, :session_tree_tmux, runner: fn _, _, _ -> {"", 0} end)
    view |> element("#sessions-retry") |> render_click()
    refute has_element?(view, "#sessions-tmux-error")
  end

  test "collapse survives refresh and ended rows stay hidden until checked", %{conn: conn} do
    parent = agent_session(name: "main", kind: "main_coordinator")
    child = agent_session(parent_id: parent.id)
    ended = agent_session(name: "ended") |> Foreman.AgentSessions.end_session()
    {:ok, view, _} = live(conn, "/sessions")
    view |> element("#collapse-#{parent.id}") |> render_click()
    assert has_element?(view, "#tree-row-#{child.id}[hidden]")
    send(view.pid, {:notification, :foreman_events, "{}"})
    assert has_element?(view, "#tree-row-#{child.id}[hidden]")
    refute has_element?(view, "#tree-row-#{ended.id}")
    view |> element("#show-ended-form") |> render_change(%{"ended" => "true"})
    assert has_element?(view, "#tree-row-#{ended.id}")
    assert has_element?(view, "#focus-#{ended.id}[disabled]")
  end

  test "strip has Show all and expands", %{conn: conn} do
    for n <- 1..7 do
      row = agent_session(name: "waiting-#{n}")
      Foreman.AgentSessions.fire(row, :permission_prompt)
    end

    {:ok, view, _} = live(conn, "/sessions")
    assert has_element?(view, "#show-all-waiting", "Show all 7")
    assert has_element?(view, "#waiting-sessions.bb-session-waiting-capped")
    view |> element("#show-all-waiting") |> render_click()
    refute has_element?(view, "#waiting-sessions.bb-session-waiting-capped")
  end

  test "note delivers once through the terminal boundary and reports its count", %{conn: conn} do
    agent_session(kind: "main_coordinator", harness: "claude", name: "main", pane_id: "%1")
    parent = self()

    runner = fn "tmux", args, _ ->
      cond do
        "list-panes" in args ->
          if Enum.any?(args, &String.contains?(&1, "window_activity")),
            do: {"%1\t@1\tscratch\tmain\t1\t\t\t0\t1\t0\t0,0", 0},
            else: {"%1\t@1\tscratch\tmain\t1", 0}

        "capture-pane" in args ->
          {"───\n❯\n───", 0}

        "send-keys" in args ->
          send(parent, {:keys, args})
          {"", 0}
      end
    end

    Application.put_env(:foreman, :session_tree_tmux, runner: runner, key_delay: 0)
    {:ok, view, _} = live(conn, "/sessions")
    view |> element("#note-coordinators") |> render_click()
    view |> form("#coordinator-note-form", note: %{text: "Check reports"}) |> render_submit()
    assert has_element?(view, "#note-result", "Sent to 1 coordinators.")

    assert_receive {:keys,
                    [
                      "-N",
                      "-L",
                      _,
                      "send-keys",
                      "-t",
                      "%1",
                      "-l",
                      "--",
                      "[foreman note from board] Check reports"
                    ]}

    assert_receive {:keys, ["-N", "-L", _, "send-keys", "-t", "%1", "Enter"]}
    refute_receive {:keys, _}
  end

  test "note reports delivered and closed coordinators", %{conn: conn} do
    agent_session(kind: "main_coordinator", harness: "claude", name: "main")
    |> Foreman.AgentSessions.end_session()

    {:ok, view, _} = live(conn, "/sessions")
    view |> element("#note-coordinators") |> render_click()
    view |> form("#coordinator-note-form", note: %{text: "Check the reports"}) |> render_submit()
    assert has_element?(view, "#note-result", "Sent to 0 coordinators.")
    assert has_element?(view, "#note-skipped", "Not sent to main: the pane is closed.")
  end

  test "waiting session appears in strip and tree and broadcasts refresh both", %{conn: conn} do
    row = agent_session(name: "tree-build")
    {:ok, view, _} = live(conn, "/sessions")
    assert has_element?(view, "#tree-row-#{row.id}")
    refute has_element?(view, "#waiting-#{row.id}")
    {:ok, _, _} = Foreman.AgentSessions.fire(row, :permission_prompt)
    send(view.pid, {:notification, :foreman_events, Jason.encode!(%{type: :sessions_changed})})
    assert has_element?(view, "#waiting-#{row.id}", "Permission prompt · open the terminal")
    assert has_element?(view, "#tree-state-#{row.id}-label", "Waiting on you")
  end
end
