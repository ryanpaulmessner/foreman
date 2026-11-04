defmodule ForemanWeb.OpenCardTest do
  @moduledoc "The compact open card on Needs you (fm-zgd.17.2; spec Decisions 12-20, 23, 40)."
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Foreman.AgentSessionFixtures
  import Mimic
  setup :set_mimic_global
  alias Foreman.Requests

  setup do
    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "s-1", title: "A ticket", issue_type: "task", status: "open"})
    )

    :ok
  end

  defp insert(kind, facts, attrs \\ %{}) do
    Foreman.Repo.insert!(
      struct(
        %Foreman.Requests.Request{
          repo_key: "sample",
          bead_id: "s-1",
          kind: kind,
          actor: "pi",
          state: "pending",
          facts: facts
        },
        attrs
      )
    )
  end

  @sha String.duplicate("a", 40)
  @kinds [
    {"decision",
     %{
       "question" => "Which?",
       "options" => ["A", "B"],
       "text" => "What: x\nWhy now: y"
     }, "Decision", "Answer", "Answering…"},
    {"review_ui",
     %{
       "question" => "Check it?",
       "options" => ["Looks right"],
       "images" => [%{"path" => "/repo/a.png", "width" => 1440, "theme" => "light"}]
     }, "UI review", "Answer", "Answering…"},
    {"batch", %{"question" => "File these?", "items" => [%{"id" => "a", "label" => "First"}]},
     "Batch", "Submit", "Submitting…"},
    {"chore", %{"question" => "Merge it", "steps" => ["Open it.", "Merge it."]}, "Chore", "Done",
     "Saving…"},
    {"push",
     %{
       "remote" => "o/r",
       "remote_branch" => "b",
       "local_branch" => "b",
       "expected_sha" => @sha,
       "worktree" => "/tmp/w"
     }, "Push", "Approve", "Approving…"},
    {"open_pr",
     %{
       "remote" => "o/r",
       "head_branch" => "b",
       "base_branch" => "main",
       "expected_sha" => @sha,
       "title" => "T",
       "body" => "B"
     }, "Open PR", "Approve", "Approving…"},
    {"merge", %{"remote" => "o/r", "number" => 3, "expected_sha" => @sha}, "Merge", "Approve",
     "Approving…"}
  ]

  test "each kind: one border, the header line, its body, and one footer strip", %{conn: conn} do
    requests = for {kind, facts, _, _, _} <- @kinds, do: insert(kind, facts)
    {:ok, view, _} = live(conn, "/needs-you")

    for {request, {kind, _, badge, primary, busy}} <- Enum.zip(requests, @kinds) do
      card = "#card-open-#{request.id}"
      assert has_element?(view, "#{card}.bb-qcard")
      assert has_element?(view, "#{card} .bb-qhead", badge)
      assert has_element?(view, "#{card} .bb-qhead #ticket-link-#{request.id}", "s-1")
      assert has_element?(view, "#{card} .bb-qhead-title[title='A ticket']", "A ticket")
      assert has_element?(view, "#{card} .bb-qhead time[title]")
      assert has_element?(view, "#{card} #card-source-#{request.id}")

      # One footer strip with one filled button: the kind's primary with its busy text.
      footer = "#card-footer-#{request.id}"
      assert has_element?(view, "#{card} #{footer}.bb-qfoot")

      [filled] =
        view
        |> element(card)
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("button[phx-disable-with]")
        |> Enum.filter(&(LazyHTML.text(&1) |> String.trim() == primary))

      assert LazyHTML.attribute(filled, "phx-disable-with") == [busy]

      decline? = kind in ~w(decision review_ui push open_pr merge)
      assert has_element?(view, "#{footer} #submit-decline-#{request.id}", "Decline") == decline?
      assert has_element?(view, "#{footer} textarea[placeholder='Note (optional)']") == decline?
      assert has_element?(view, "#{footer} #always-#{request.id}") == (kind == "decision")

      for action <- ["ask", "wrong-question", "withdraw"],
          do: assert(has_element?(view, "#{footer} .bb-qlinks #card-#{action}-#{request.id}"))
    end

    [decision, review, batch, chore, push, open_pr, merge] = requests
    assert has_element?(view, "#card-open-#{decision.id} .bb-opt input[type=radio]")
    assert has_element?(view, "#card-open-#{review.id} #review-images-#{review.id}")
    assert has_element?(view, "#card-open-#{batch.id} .bb-opt input[type=checkbox]")
    assert has_element?(view, "#chore-steps-#{chore.id} li", "Merge it.")
    assert has_element?(view, "#card-open-#{push.id} dt", "Destination")
    assert has_element?(view, "#card-open-#{open_pr.id} dt", "Head branch")
    assert has_element?(view, "#card-open-#{merge.id} dt", "Pull request")
  end

  test "Always sits on the footer's second row with the text actions at its right", %{
    conn: conn
  } do
    request = insert("decision", %{"question" => "Which?", "options" => ["A"]})
    {:ok, view, _} = live(conn, "/needs-you")
    [row1, row2] = rows(view, request)
    assert LazyHTML.query(row1, "#decision-note-#{request.id}") |> Enum.count() == 1
    assert LazyHTML.query(row1, "#submit-answer-#{request.id}") |> Enum.count() == 1
    assert LazyHTML.query(row2, "#always-#{request.id}") |> Enum.count() == 1
    assert LazyHTML.text(row2) =~ "Always use this answer"

    assert row2
           |> LazyHTML.query(".bb-qlinks button")
           |> Enum.map(&String.trim(LazyHTML.text(&1))) ==
             ["Ask about this", "Wrong question", "Withdraw"]
  end

  defp rows(view, request) do
    view
    |> element("#card-footer-#{request.id}")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#card-footer-#{request.id} > .bb-qrow")
    |> Enum.to_list()
  end

  test "P1 and P2: one panel at a time, a second click closes it, opening scrolls up", %{
    conn: conn
  } do
    request = insert("decision", %{"question" => "Which?", "options" => ["A"]})
    {:ok, view, _} = live(conn, "/needs-you")
    id = request.id
    panels = ["#card-ask-panel-#{id}", "#wrong-question-#{id}", "#withdraw-#{id}"]
    open = fn -> Enum.filter(panels, &has_element?(view, &1)) end
    assert open.() == []

    for {action, panel} <- Enum.zip(["ask", "wrong-question", "withdraw"], panels) do
      view |> element("#card-#{action}-#{id}") |> render_click()
      assert open.() == [panel]
      assert has_element?(view, ~s(#card-#{action}-#{id}[aria-expanded="true"]))
      assert_push_event(view, "card-scroll-top", %{id: "card-open-" <> ^id})
    end

    view |> element("#card-withdraw-#{id}") |> render_click()
    assert open.() == []
    refute_push_event(view, "card-scroll-top", _)
  end

  test "panel text is kept on the server when another panel opens", %{conn: conn} do
    request = insert("decision", %{"question" => "Which?", "options" => ["A"]})
    {:ok, view, _} = live(conn, "/needs-you")
    id = request.id

    view |> element("#card-wrong-question-#{id}") |> render_click()

    view
    |> form("#wrong-question-#{id}", wrong_question: %{reason: "Asked twice"})
    |> render_change()

    view |> element("#card-withdraw-#{id}") |> render_click()
    view |> form("#withdraw-#{id}", withdraw: %{reason: "Stale"}) |> render_change()
    view |> element("#card-wrong-question-#{id}") |> render_click()
    assert has_element?(view, "#wrong-question-reason-#{id}", "Asked twice")
    send(view.pid, :reconcile)
    assert has_element?(view, "#wrong-question-reason-#{id}", "Asked twice")
    view |> element("#card-withdraw-#{id}") |> render_click()
    assert has_element?(view, ~s(#withdraw-reason-#{id}[value="Stale"]))
  end

  test "the panels use the Decision 18 copy", %{conn: conn} do
    request = insert("decision", %{"question" => "Which?", "options" => ["A"]})
    {:ok, view, _} = live(conn, "/needs-you")
    id = request.id

    view |> element("#card-wrong-question-#{id}") |> render_click()
    assert has_element?(view, "#wrong-question-#{id} label", "What is wrong with the question?")

    assert has_element?(
             view,
             "#submit-wrong-question-#{id}[phx-disable-with='Sending…']",
             "Send as wrong question"
           )

    assert has_element?(
             view,
             "#wrong-question-#{id}",
             "The card closes and the agent gets your reason."
           )

    view |> element("#card-withdraw-#{id}") |> render_click()
    assert has_element?(view, "#withdraw-#{id} label", "Reason")

    assert has_element?(
             view,
             "#submit-withdraw-#{id}[phx-disable-with='Withdrawing…']",
             "Withdraw card"
           )

    assert has_element?(view, "#withdraw-#{id}", "The card closes. The agent gets the reason.")

    view |> form("#withdraw-#{id}", withdraw: %{reason: "Done in chat"}) |> render_submit()
    assert %{state: "withdrawn"} = Requests.get(id)
  end

  test "an ended source's Ask about this copies the question instead of sending", %{conn: conn} do
    request = insert("decision", %{"question" => "Which?", "options" => ["A"]})
    row = agent_session(name: "gone-build", pane_id: "%5") |> Foreman.AgentSessions.end_session()
    asked_by(request, row)
    {:ok, view, _} = live(conn, "/needs-you")
    view |> element("#card-ask-#{request.id}") |> render_click()

    assert has_element?(
             view,
             "#card-question-hint-#{request.id}",
             "The session that asked has ended, so the board cannot send this question."
           )

    refute has_element?(view, "#card-question-send-#{request.id}")
    assert has_element?(view, "#card-question-copy-#{request.id}[phx-hook=CopyField]")
  end

  test "text with no What and no Why now shows as today, with Show more", %{conn: conn} do
    long = Enum.map_join(1..12, "\n\n", &"Paragraph #{&1} of the agent's notes.")
    request = insert("decision", %{"question" => "Which?", "options" => ["A"], "text" => long})
    {:ok, view, _} = live(conn, "/needs-you")
    refute has_element?(view, "#card-context-#{request.id}")
    assert has_element?(view, "#text-#{request.id}.fm-clamp", "Paragraph 1")
    assert has_element?(view, "#text-#{request.id}-more", "Show more")
  end

  test "What and Why now clamp to 2 lines; Part of, From and notes fold under More context", %{
    conn: conn
  } do
    text =
      "**What:** the page\n**Part of:** fm-9mm\n**From:** chat\n**Why now:** the build waits\n\nA note."

    request = insert("decision", %{"question" => "Which?", "options" => ["A"], "text" => text})
    {:ok, view, _} = live(conn, "/needs-you")
    ctx = "#card-context-#{request.id}"
    assert has_element?(view, "#{ctx} > dl dt", "What")
    assert has_element?(view, "#{ctx} > dl dd.bb-clamp-2", "the page")
    assert has_element?(view, "#{ctx} > dl dd.bb-clamp-2", "the build waits")
    refute has_element?(view, "#{ctx} > dl dt", "Part of")

    more = "#{ctx}-more"

    assert has_element?(
             view,
             "#{more} summary .bb-when-closed",
             "More context: Part of, From, agent notes"
           )

    assert has_element?(view, "#{more} summary .bb-when-open", "Less context")
    assert has_element?(view, "#{more} dd", "fm-9mm")
    assert has_element?(view, "#{more} dd", "chat")
    assert has_element?(view, "#{more} .bb-extra", "A note.")
  end

  test "no card at load shows a tmux command or the old source lines (spec acceptance 3)", %{
    conn: conn
  } do
    coordinator = agent_session(name: "foreman-board", kind: "main_coordinator", pane_id: "%1")
    live_row = agent_session(name: "live-build", parent_id: coordinator.id, pane_id: "%2")

    ended =
      agent_session(name: "ended-build", pane_id: "%3") |> Foreman.AgentSessions.end_session()

    facts = %{"question" => "Which?", "options" => ["A"]}

    live_card = insert("decision", facts) |> asked_by(live_row)
    ended_card = insert("decision", facts) |> asked_by(ended)
    unknown = insert("decision", facts)
    {:ok, view, html} = live(conn, "/needs-you")
    render_click(view, "open-request-drawer")

    for text <- ["tmux ", "Go to session", "Source unknown ·", "This session has ended."] do
      refute html =~ text
      refute render(view) =~ text
    end

    assert has_element?(view, "#card-source-#{live_card.id}", "build under foreman-board")
    assert has_element?(view, "#card-source-#{live_card.id} .bb-dot:not(.bb-dot-off)")
    assert has_element?(view, "#card-source-#{ended_card.id} .bb-dot-off")
    assert has_element?(view, "#card-source-#{ended_card.id} time[title]")
    assert has_element?(view, "#card-focus-#{ended_card.id}[disabled]")
    refute has_element?(view, "#card-focus-#{unknown.id}")

    # Hidden until fm-9mm.12 and fm-9mm.15: the session link and the answer's receiver.
    refute has_element?(view, "#card-source-#{live_card.id} a")
    refute render(view) =~ "answer goes to"
    refute render(view) =~ "Find the session"
  end

  test "session waiting notices use the info line and the Decision 20 copy", %{conn: conn} do
    session =
      Foreman.Repo.insert!(%Foreman.PlanningSession{
        project: "sample",
        ticket: "s-1",
        workdir: "/tmp",
        window: "@42",
        state: :running,
        launched_at: DateTime.utc_now()
      })
      |> tap(&Foreman.AgentSessions.sync_planning/1)

    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "session_waiting", %{
        "session" => session.session_id,
        "facts" => %{"reason" => "permission", "tool" => "p-1", "tool_name" => "Bash"}
      })

    {:ok, view, _} = live(conn, "/needs-you")
    # Open session is the one filled button; it sits in the footer strip.
    assert has_element?(view, "#card-footer-#{request.id} #open-#{request.id}", "Open session")

    for {error, text} <- [
          window_gone: "The session window is closed.",
          tmux_unavailable: "tmux does not answer. Try again.",
          no_client: "No terminal is attached."
        ] do
      stub(Foreman.SessionTmux, :open_session, fn _, _ -> {:error, error} end)
      view |> element("#open-#{request.id}") |> render_click()
      assert has_element?(view, "#notice-#{request.id}.bb-status-info", text)
    end
  end
end
