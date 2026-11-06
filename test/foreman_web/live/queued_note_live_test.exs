defmodule ForemanWeb.QueuedNoteLiveTest do
  @moduledoc """
  The lines for a note that waits for a busy coordinator (fm-9mm.23): on the card after
  you answer an ended build's card, in Recent outcomes, and on the build's session page
  after Relaunch build. Each says that the note waits and changes when it is sent.
  tmux is a stand-in whose screen the test switches from busy to idle.
  """
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Foreman.AgentSessionFixtures
  alias Foreman.{AgentSessions, QueuedNotes, Requests}

  @busy "✳ Working… (3s)\n───\n❯ \n───\nesc to interrupt\n"
  @idle "───\n❯ \n───\n"

  setup do
    {:ok, screen} = Agent.start_link(fn -> @busy end)
    test = self()

    runner = fn "tmux", args, _ ->
      cond do
        "list-panes" in args -> {"%1\t@1\tforeman\tfm-epic\t1\n", 0}
        "capture-pane" in args -> {Agent.get(screen, & &1), 0}
        "-l" in args -> send(test, {:typed, List.last(args)}) && {"", 0}
        true -> {"", 0}
      end
    end

    Application.put_env(:foreman, :session_controls_tmux, runner: runner, key_delay: 0)
    # Result lines that expire tell the test instead of waiting 10 s.
    Application.put_env(:foreman, :card_line_timer, fn _, message, _ ->
      send(test, {:card_line_timer, message})
    end)

    on_exit(fn ->
      Application.put_env(:foreman, :session_controls_tmux, runner: &Foreman.TestTmux.no_panes/3)
      Application.delete_env(:foreman, :card_line_timer)
    end)

    coordinator =
      agent_session(name: "fm-epic", kind: "epic_coordinator", harness: "claude", pane_id: "%1")

    build =
      agent_session(
        name: "build-asked",
        parent_id: coordinator.id,
        pane_id: "%5",
        ticket: "fm-9mm.23",
        branch: "feat/asked"
      )

    request =
      Foreman.Repo.insert!(%Foreman.Requests.Request{
        repo_key: "foreman",
        bead_id: "fm-9mm.23",
        kind: "decision",
        actor: "pi",
        state: "pending",
        session: build.name,
        agent_session_id: build.id,
        facts: %{"question" => "Keep the line?", "options" => ["Keep it", "Drop it"]}
      })

    %{request: request, build: AgentSessions.end_session(build), screen: screen}
  end

  defp idle(ctx), do: Agent.update(ctx.screen, fn _ -> @idle end)

  defp answer(view, r) do
    view
    |> form("#decision-#{r.id}", decision: %{choice: "Keep it"})
    |> render_submit(%{"action" => "answer"})
  end

  # What the page does on a board event: reload.
  defp board_event(view) do
    send(view.pid, {:notification, :foreman_events, %{"kind" => "requests_changed"}})
    render(view)
  end

  test "the card says the note waits, and the line changes when it is sent (acceptance 2)",
       %{conn: conn, request: r} = ctx do
    {:ok, view, _} = live(conn, "/needs-you?card=#{r.id}")
    answer(view, r)

    refute_received {:typed, _}
    assert %{state: "answered"} = Requests.get(r.id)

    assert has_element?(
             view,
             "#card-result-#{r.id}",
             "The note to fm-epic waits until its prompt is idle."
           )

    # A waiting line stays: no 10 s timer yet.
    refute_received {:card_line_timer, _}
    assert has_element?(view, "#card-note-withdraw-#{r.id}", "Do not send")
    assert has_element?(view, "#card-result-close-#{r.id}")

    idle(ctx)
    QueuedNotes.run()
    assert_received {:typed, _}
    board_event(view)

    assert has_element?(view, "#card-result-#{r.id}", "Sent to fm-epic")
    assert has_element?(view, "#card-result-#{r.id}", "as a note with the question.")
    refute has_element?(view, "#card-result-#{r.id}", "waits")
    refute has_element?(view, "#card-note-withdraw-#{r.id}")
    refute has_element?(view, "#card-result-close-#{r.id}")
    assert_received {:card_line_timer, {:line_expired, id}}
    assert id == r.id
  end

  test "Recent outcomes shows the note's state on the answered card",
       %{conn: conn, request: r} = ctx do
    {:ok, _} = Requests.resolve(r.id, :answer, %{"answer" => "Keep it"})
    {:ok, view, _} = live(conn, "/needs-you")

    assert has_element?(
             view,
             "#recent-#{r.id}-note",
             "The note to fm-epic waits until its prompt is idle."
           )

    idle(ctx)
    QueuedNotes.run()
    board_event(view)
    assert has_element?(view, "#recent-#{r.id}-note", "Sent to fm-epic")
  end

  test "Do not send stops the waiting note", %{conn: conn, request: r} = ctx do
    {:ok, view, _} = live(conn, "/needs-you?card=#{r.id}")
    answer(view, r)
    view |> element("#card-note-withdraw-#{r.id}") |> render_click()

    assert has_element?(view, "#card-result-#{r.id}", "The note to fm-epic was not sent.")
    assert %{state: "withdrawn"} = QueuedNotes.for_request(r.id)

    idle(ctx)
    QueuedNotes.run()
    refute_received {:typed, _}
  end

  test "a coordinator that ends while the note waits: the line says so", %{conn: conn, request: r} do
    {:ok, view, _} = live(conn, "/needs-you?card=#{r.id}")
    answer(view, r)
    AgentSessions.end_session(AgentSessions.live_by_name("fm-epic"))
    board_event(view)

    assert has_element?(
             view,
             "#card-result-#{r.id}",
             "The note to fm-epic waits until fm-epic resumes."
           )
  end

  test "Relaunch build on a busy coordinator: the session page says the note waits, then that it was sent",
       %{conn: conn} = ctx do
    other =
      AgentSessions.end_session(
        agent_session(
          name: "build-b",
          parent_id: AgentSessions.live_by_name("fm-epic").id,
          ticket: "fm-9mm.23",
          branch: "feat/b"
        )
      )

    {:ok, view, _} = live(conn, "/sessions/#{other.id}")
    view |> element("#session-control-relaunch_build") |> render_click()

    assert has_element?(
             view,
             "#session-result",
             ~s(fm-epic is busy. Saved the note: "Relaunch the build for fm-9mm.23 on feat/b.")
           )

    assert has_element?(
             view,
             "#session-note",
             "The relaunch note to fm-epic waits until its prompt is idle."
           )

    idle(ctx)
    QueuedNotes.run()
    send(view.pid, {:notification, :foreman_events, %{"kind" => "sessions_changed"}})
    assert has_element?(view, "#session-note", "Sent fm-epic the relaunch note")
  end
end
