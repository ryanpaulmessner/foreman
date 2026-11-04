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

      # One text box for every kind; Ask, Wrong question and Withdraw use it.
      assert has_element?(view, "#{footer} textarea#card-text-#{request.id}[name$='[note]']")
      assert has_element?(view, "#{footer} #card-ask-#{request.id}", "Ask")

      for action <- ["wrong-question", "withdraw"],
          do: assert(has_element?(view, "#{footer} .bb-qlinks #card-#{action}-#{request.id}"))

      # No Always on cards (Ryan, card 8ff81918); no footer panels (card 602ad7c1).
      refute has_element?(view, "#always-#{request.id}")
      refute render(element(view, card)) =~ "Always use this answer"
      refute has_element?(view, "#card-ask-panel-#{request.id}")
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

  test "the footer: the text box and the buttons, then Wrong question and Withdraw at the right",
       %{conn: conn} do
    request = insert("decision", %{"question" => "Which?", "options" => ["A"]})
    {:ok, view, _} = live(conn, "/needs-you")
    [row1, row2] = rows(view, request)

    assert row1 |> LazyHTML.query("textarea, button") |> Enum.map(&id/1) ==
             Enum.map(~w(card-text submit-answer submit-decline card-ask), &"#{&1}-#{request.id}")

    assert row2
           |> LazyHTML.query(".bb-qlinks button")
           |> Enum.map(&String.trim(LazyHTML.text(&1))) == ["Wrong question", "Withdraw"]
  end

  defp id(node), do: node |> LazyHTML.attribute("id") |> hd()

  defp rows(view, request) do
    view
    |> element("#card-footer-#{request.id}")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#card-footer-#{request.id} > .bb-qrow")
    |> Enum.to_list()
  end

  defp type(view, request, text) do
    view
    |> form("#decision-#{request.id}", decision: %{note: text})
    |> render_change()
  end

  test "Ask, Wrong question and Withdraw are off until there is text", %{conn: conn} do
    facts = Foreman.DecisionFacts.valid(%{"question" => "Which?", "options" => ["A"]})
    request = insert("decision", facts)
    {:ok, view, _} = live(conn, "/needs-you")
    id = request.id

    for action <- ["ask", "wrong-question", "withdraw"] do
      assert has_element?(view, "#card-#{action}-#{id}[disabled][data-needs-text]")
    end

    # The browser turns them on as you type (CardText hook); the server keeps the text,
    # so a later redraw of the card shows them on.
    assert has_element?(view, "#card-text-#{id}[phx-hook=CardText]")
    type(view, request, "Asked twice")
    {:ok, _} = Requests.update(id, "pi", nil, %{"question" => "Which one?"})
    send(view.pid, :reconcile)
    assert has_element?(view, "#card-text-#{id}", "Asked twice")

    for action <- ["ask", "wrong-question", "withdraw"] do
      assert has_element?(view, "#card-#{action}-#{id}:not([disabled])")
    end
  end

  test "the button decides: the primary sends the text as its note", %{conn: conn} do
    request = insert("decision", %{"question" => "Which?", "options" => ["A", "B"]})
    {:ok, view, _} = live(conn, "/needs-you")

    view
    |> form("#decision-#{request.id}", decision: %{choice: "B", note: "Keep it short"})
    |> render_submit(%{"action" => "answer"})

    assert %{state: "answered", outcome: %{"answer" => "B"}, note: "Keep it short"} =
             Requests.get(request.id)
  end

  test "Wrong question and Withdraw use the text as their reason; no text, no change", %{
    conn: conn
  } do
    wrong = insert("decision", %{"question" => "Which?", "options" => ["A"]})
    gone = insert("decision", %{"question" => "Other?", "options" => ["A"]})
    {:ok, view, _} = live(conn, "/needs-you")

    render_click(view, "resolve", %{"id" => wrong.id, "action" => "wrong-question"})

    render_click(view, "resolve", %{
      "id" => gone.id,
      "action" => "withdraw",
      "decision" => %{"note" => " "}
    })

    assert Requests.get(wrong.id).state == "pending"
    assert Requests.get(gone.id).state == "pending"

    view
    |> form("#decision-#{wrong.id}", decision: %{note: "Asked twice"})
    |> render_submit(%{"action" => "wrong-question"})

    view
    |> form("#decision-#{gone.id}", decision: %{note: "Done in chat"})
    |> render_submit(%{"action" => "withdraw"})

    assert %{state: "wrong_question", note: "Asked twice"} = Requests.get(wrong.id)
    assert %{state: "withdrawn"} = Requests.get(gone.id)
    refute has_element?(view, "#request-#{wrong.id}")
    refute has_element?(view, "#request-#{gone.id}")
  end

  test "a card sets no standing answer, even from a forged Always", %{conn: conn} do
    request = insert("decision", %{"question" => "Which?", "options" => ["A"]})
    {:ok, view, _} = live(conn, "/needs-you")

    view
    |> form("#decision-#{request.id}", decision: %{choice: "A"})
    |> render_submit(%{
      "action" => "answer",
      "decision" => %{"choice" => "A", "always" => "true"}
    })

    assert Requests.get(request.id).state == "answered"
    assert Foreman.Answers.standing() == []
  end

  test "Ask on an ended source shows the copy field with the text instead of sending", %{
    conn: conn
  } do
    request = insert("decision", %{"question" => "Which?", "options" => ["A"]})
    row = agent_session(name: "gone-build", pane_id: "%5") |> Foreman.AgentSessions.end_session()
    asked_by(request, row)
    {:ok, view, _} = live(conn, "/needs-you")

    view
    |> form("#decision-#{request.id}", decision: %{note: "Why A?"})
    |> render_submit(%{"action" => "ask"})

    assert has_element?(
             view,
             "#card-question-hint-#{request.id}",
             "The session that asked has ended, so the board cannot send this question."
           )

    assert has_element?(
             view,
             ~s(#card-question-copy-#{request.id}[phx-hook=CopyField] input[value="[card question #{request.id}] Why A?"])
           )

    assert has_element?(view, "#card-text-#{request.id}", "Why A?")
    assert Requests.get(request.id).state == "pending"
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
