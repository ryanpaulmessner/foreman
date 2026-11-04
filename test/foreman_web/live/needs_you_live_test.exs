defmodule ForemanWeb.NeedsYouLiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mimic
  alias Foreman.Requests
  setup :set_mimic_global

  setup do
    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "s-1", title: "A ticket", issue_type: "task", status: "open"})
    )

    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "actor" => "pi",
        "session" => "build",
        "facts" => %{
          "question" => "Which layout?",
          "options" => ["Wide", "Compact"],
          "recommendation" => "Compact",
          "text" => "What: Layout\nPart of: Cards\nWhy now: Review",
          "option_details" => %{"Wide" => "Use wide layout", "Compact" => "Use compact layout"}
        }
      })

    %{request: request}
  end

  test "an ended source shows its end time and the Focus icon off", %{
    conn: conn,
    request: request
  } do
    assert {:ok, %{id: id}} =
             Foreman.SessionRegistry.register(%{
               "name" => "build",
               "pane" => "%99999999",
               "workdir" => "/tmp",
               "harness" => "pi"
             })

    request
    |> Ecto.Changeset.change(agent_session_id: id)
    |> Foreman.Repo.update!()

    assert :ok = Foreman.SessionRegistry.reconcile(runner: fn _, _, _ -> {"", 0} end)
    {:ok, view, _} = live(conn, "/needs-you")
    source = "#card-source-#{request.id}"
    assert has_element?(view, source, "Asked by")
    assert has_element?(view, "#{source} .bb-src-name", "build")
    assert has_element?(view, source, "ended")
    # The end time in the shared format, with the full time on hover.
    assert has_element?(view, "#{source} time[title]")

    assert has_element?(
             view,
             ~s(#card-focus-#{request.id}[disabled][title="The pane is closed"][aria-label="The pane is closed"])
           )

    refute render(view) =~ "This session has ended."
    refute render(view) =~ "Go to session"
    refute has_element?(view, "#go-session-#{request.id}")
  end

  test "every card has its ticket in the header, context from its text, and can be withdrawn",
       %{conn: conn, request: request} do
    {:ok, view, _} = live(conn, "/needs-you")
    assert has_element?(view, "#request-#{request.id} [data-ticket-heading]", "A ticket")
    assert has_element?(view, "#card-open-#{request.id} .bb-qhead", "Decision")
    assert has_element?(view, "#card-open-#{request.id} .bb-qhead-title[title='A ticket']")
    # What and Why now from the card text; the board's own context block is gone (c)8.
    assert has_element?(view, "#card-context-#{request.id} dd", "Layout")
    assert has_element?(view, "#card-context-#{request.id} dd", "Review")
    assert has_element?(view, "#card-context-#{request.id}-more summary", "More context: Part of")
    refute has_element?(view, "#context-#{request.id}")

    for word <- ["One-off", "Internal", "Unsorted"],
        do: refute(has_element?(view, "#request-#{request.id}", word))

    # An unregistered asker: the unknown source and no tmux command (spec acceptance 3).
    assert has_element?(
             view,
             "#card-source-#{request.id}",
             "The board does not know which session asked this."
           )

    refute has_element?(view, "#card-source-#{request.id}", "Source unknown ·")
    refute has_element?(view, "#card-focus-#{request.id}")
    refute has_element?(view, "#copy-session-#{request.id}")
    refute render(view) =~ "tmux "
    assert has_element?(view, "#card-withdraw-#{request.id}[disabled]")

    view
    |> form("#decision-#{request.id}", decision: %{note: "Answered in chat"})
    |> render_submit(%{"action" => "withdraw"})

    refute has_element?(view, "#request-#{request.id}")
    assert has_element?(view, "#recent-requests", "withdrawn")
    assert has_element?(view, "#recent-requests", "Answered in chat")
    assert Requests.get(request.id).state == "withdrawn"
  end

  test "a registered coordinator card keeps its own Focus target after dispatch", %{
    conn: conn
  } do
    old = System.get_env("PREVIEW")
    System.put_env("PREVIEW", "1")

    on_exit(fn ->
      if old, do: System.put_env("PREVIEW", old), else: System.delete_env("PREVIEW")
    end)

    assert {:ok, _} =
             Foreman.SessionRegistry.register(%{
               "name" => "coordinator",
               "pane" => "%99999998",
               "workdir" => "/tmp",
               "harness" => "claude"
             })

    assert {200, _} =
             Foreman.Agent.event("sample", "s-1", %{
               "event" => "dispatch",
               "actor" => "pi",
               "session" => "build",
               "payload" => %{"window" => "%99999999", "harness" => "pi"}
             })

    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "actor" => "claude",
        "session" => "coordinator",
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Proceed?"})
      })

    {:ok, view, _} = live(conn, "/needs-you")
    assert has_element?(view, "#card-source-#{request.id} .bb-src-name", "coordinator")
    assert has_element?(view, "#card-source-#{request.id}", "main coordinator")
    assert Foreman.RequestSource.view(Requests.get(request.id)).source.target == "%99999998"
    view |> element("#card-focus-#{request.id}") |> render_click()

    assert has_element?(
             view,
             "#card-focus-info-#{request.id}.bb-status-info",
             "Could not focus the terminal. tmux does not answer."
           )
  end

  test "registered sources show the Asked by row and the Focus icon on page and drawer", %{
    conn: conn
  } do
    old = System.get_env("PREVIEW")
    System.put_env("PREVIEW", "1")

    on_exit(fn ->
      if old, do: System.put_env("PREVIEW", old), else: System.delete_env("PREVIEW")
    end)

    assert {200, _} =
             Foreman.Agent.event("sample", "s-1", %{
               "event" => "dispatch",
               "actor" => "pi",
               "session" => "relay-build",
               "payload" => %{"window" => "%99999999", "harness" => "pi", "workdir" => "/tmp"}
             })

    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "actor" => "pi",
        "session" => "relay-build",
        "facts" => %{
          "question" => "Which?",
          "options" => ["A"],
          "option_details" => %{"A" => "Keep access enabled"},
          "text" => "What: Access\nPart of: Cards\nWhy now: Review"
        }
      })

    {:ok, view, _} = live(conn, "/needs-you")
    render_click(view, "open-request-drawer")

    for prefix <- ["", "drawer-"] do
      source = "##{prefix}card-source-#{request.id}"
      assert has_element?(view, "#{source} .bb-src-name", "relay-build")
      assert has_element?(view, source, "build")
      assert has_element?(view, source, "live")

      assert has_element?(
               view,
               ~s|##{prefix}card-focus-#{request.id}[title="Focus terminal"]:not([disabled])|
             )

      assert has_element?(view, "##{prefix}option-detail-#{request.id}-0", "Keep access enabled")
      view |> element("##{prefix}card-focus-#{request.id}") |> render_click()
      assert has_element?(view, "##{prefix}card-focus-info-#{request.id}", "tmux does not answer")
    end

    assert Foreman.RequestSource.view(Requests.get(request.id)).source.target == "%99999999"
  end

  test "the header shows the Summary title and no board context block on page and drawer", %{
    conn: conn,
    request: request
  } do
    Foreman.Beads.Projection.replace(
      "sample",
      Enum.map_join(
        [
          %{
            id: "s-e",
            title: "Mobile access",
            issue_type: "epic",
            status: "open",
            kind: "feature"
          },
          %{
            id: "s-1",
            title: "Technical title",
            issue_type: "task",
            status: "open",
            dependencies: [%{type: "parent-child", depends_on_id: "s-e"}],
            description:
              "**Ticket:** T-123\n\n## Summary\nTitle: Fix mobile login\nWhat users see: Login works on phones.\n"
          }
        ],
        "\n",
        &Jason.encode!/1
      )
    )

    {:ok, view, _} = live(conn, "/needs-you")
    render_click(view, "open-request-drawer")

    for prefix <- ["", "drawer-"] do
      card = "##{prefix}card-open-#{request.id}"

      assert has_element?(
               view,
               "##{prefix}request-#{request.id} [data-ticket-heading]",
               "Fix mobile login"
             )

      assert has_element?(view, "#{card} .bb-qhead-title", "Fix mobile login")
      refute has_element?(view, "##{prefix}context-#{request.id}")

      # Decision 13: the board's Kind, Part of, From and summary lines go away.
      for text <- ["Feature", "Mobile access", "Support Board T-123", "Login works on phones."],
          do: refute(has_element?(view, card, text))
    end
  end

  test "a failed Focus terminal says why under the source row", %{conn: conn, request: request} do
    row = Foreman.AgentSessionFixtures.agent_session(name: "build", pane_id: "%99999999")
    Foreman.AgentSessionFixtures.asked_by(request, row)
    {:ok, view, _} = live(conn, "/needs-you")
    render_click(view, "open-request-drawer")

    for {error, text} <- [
          window_gone: "Could not focus the terminal. The window is closed.",
          tmux_unavailable: "Could not focus the terminal. tmux does not answer.",
          no_client: "Could not focus the terminal. No terminal is attached."
        ],
        prefix <- ["", "drawer-"] do
      stub(Foreman.RequestSource, :focus, fn _ -> {:error, error} end)
      view |> element("##{prefix}card-focus-#{request.id}") |> render_click()
      line = "##{prefix}card-focus-info-#{request.id}"
      assert has_element?(view, "#{line}.bb-status-info", text)
      copy = "##{prefix}copy-session-#{request.id}"

      if error == :no_client,
        do:
          assert(
            has_element?(
              view,
              ~s(#{copy}[phx-hook=CopyField] input[value^="tmux select-window -t '%99999999'"])
            )
          ),
        else: refute(has_element?(view, copy))
    end

    stub(Foreman.RequestSource, :focus, fn _ -> :ok end)
    view |> element("#card-focus-#{request.id}") |> render_click()
    refute has_element?(view, "#card-focus-info-#{request.id}")
  end

  test "same-ticket cards have one group heading", %{conn: conn, request: request} do
    {:ok, _} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Another?"})
      })

    {:ok, view, _} = live(conn, "/needs-you")

    assert view
           |> element("#pending-requests")
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("[data-ticket-heading]")
           |> Enum.count() == 1

    view
    |> form("#decision-#{request.id}", decision: %{note: "No longer needed"})
    |> render_submit(%{"action" => "withdraw"})

    assert has_element?(view, "#pending-requests [data-ticket-heading]", "A ticket")
  end

  test "user asks cannot be withdrawn through a forged card event", %{conn: conn} do
    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "actor" => "user",
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Which?"})
      })

    {:ok, view, _} = live(conn, "/needs-you")
    refute has_element?(view, "#card-withdraw-#{request.id}")
    assert has_element?(view, "#card-wrong-question-#{request.id}")

    render_click(view, "resolve", %{
      "id" => request.id,
      "action" => "withdraw",
      "decision" => %{"note" => "Stale"}
    })

    assert Requests.get(request.id).state == "pending"
  end

  test "waiting cards share Open session and usage-only Continue on page and drawer", %{
    conn: conn
  } do
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
        "facts" => %{"reason" => "usage_limit", "provider" => "Codex", "reset_at" => "14:00"}
      })

    {:ok, view, _} = live(conn, "/needs-you")
    refute has_element?(view, "#request-#{request.id} code")
    assert has_element?(view, "#open-#{request.id}", "Open session")
    assert has_element?(view, "#continue-#{request.id}", "Continue")
    assert has_element?(view, "#request-#{request.id}", "Codex")
    assert has_element?(view, "#request-#{request.id}", "14:00")
    refute has_element?(view, "#submit-approve-#{request.id}")
    render_click(view, "open-request-drawer")
    assert has_element?(view, "#drawer-continue-#{request.id}")
    assert has_element?(view, "#drawer-open-#{request.id}")

    {:ok, input} =
      Requests.ask({"sample", "s-1"}, "session_waiting", %{
        "session" => session.session_id,
        "facts" => %{"reason" => "input", "tool" => "ask"}
      })

    send(view.pid, :reconcile)
    render(view)
    refute has_element?(view, "#continue-#{input.id}")
    assert {:error, :invalid} = Foreman.SessionWaiting.continue(input.id)
  end

  describe "session waiting cards" do
    setup do
      Foreman.Beads.Projection.replace(
        "sample",
        Enum.map_join(
          [{"s-1", "A ticket"}, {"s-2", "Pick a database"}, {"s-3", "Out of credit"}],
          "\n",
          fn {id, title} ->
            Jason.encode!(%{id: id, title: title, issue_type: "task", status: "open"})
          end
        )
      )

      sessions =
        for ticket <- ~w(s-1 s-2 s-3), into: %{} do
          {ticket,
           Foreman.Repo.insert!(%Foreman.PlanningSession{
             project: "sample",
             ticket: ticket,
             workdir: "/tmp",
             window: "@4#{String.last(ticket)}",
             state: :running,
             launched_at: DateTime.utc_now()
           })
           |> tap(&Foreman.AgentSessions.sync_planning/1)}
        end

      %{sessions: sessions}
    end

    test "every reason gets a titled card with Open session and no bare attach command", %{
      conn: conn,
      sessions: sessions
    } do
      ask = fn ticket, facts ->
        {:ok, request} =
          Requests.ask({"sample", ticket}, "session_waiting", %{
            "session" => sessions[ticket].session_id,
            "facts" => facts
          })

        request
      end

      permission =
        ask.("s-1", %{"reason" => "permission", "tool" => "p-1", "tool_name" => "Bash"})

      question =
        ask.("s-2", %{
          "reason" => "input",
          "tool" => "q-1",
          "tool_name" => "AskUserQuestion",
          "questions" => [Foreman.ScratchPrompt.question()]
        })

      limit = ask.("s-3", %{"reason" => "usage_limit", "provider" => "Anthropic"})
      requests = [permission, question, limit]

      {:ok, view, _} = live(conn, "/needs-you")
      render_click(view, "open-request-drawer")

      for request <- requests, prefix <- ["", "drawer-"] do
        card = "##{prefix}request-#{request.id}"
        assert has_element?(view, "#{card} ##{prefix}open-#{request.id}", "Open session")
        assert has_element?(view, "#{card} h2", "Planning session")
        refute has_element?(view, "#{card} code")
        refute render(element(view, card)) =~ "tmux -L"
      end

      assert has_element?(view, "#request-#{permission.id}", "Permission needed")
      assert has_element?(view, "#request-#{permission.id}", "Bash")
      assert has_element?(view, "#request-#{permission.id}", "A ticket")
      refute has_element?(view, "#answer-#{permission.id}")

      assert has_element?(view, "#question-#{question.id}", "Which database?")
      assert has_element?(view, "#answer-#{question.id}-0", "Postgres")
      assert has_element?(view, "#answer-#{question.id}-1", "SQLite")
      assert has_element?(view, "#other-text-#{question.id}")
      assert has_element?(view, "#drawer-answer-#{question.id}-0")

      assert has_element?(view, "#continue-#{limit.id}")
      refute has_element?(view, "#continue-#{question.id}")
    end

    test "the coordinator's card is titled Coordinator", %{conn: conn} do
      {:ok, request} =
        Foreman.Repo.insert(%Foreman.Requests.Request{
          repo_key: "__foreman__",
          bead_id: "coordinator",
          kind: "session_waiting",
          actor: "user",
          session: "c-1",
          facts: %{"reason" => "permission", "target" => "planning", "tool_name" => "Edit"},
          state: "pending"
        })

      {:ok, view, _} = live(conn, "/needs-you")
      assert has_element?(view, "#request-#{request.id} h2", "Coordinator")
      assert has_element?(view, "#open-#{request.id}")
    end

    test "Open session with no attached client says so and offers the attach command", %{
      conn: conn,
      sessions: sessions
    } do
      {session, _} = Foreman.ScratchPrompt.start(sessions["s-1"])

      {:ok, request} =
        Requests.ask({"sample", "s-1"}, "session_waiting", %{
          "session" => session.session_id,
          "facts" => %{"reason" => "permission", "tool" => "p-1", "tool_name" => "Bash"}
        })

      {:ok, view, _} = live(conn, "/needs-you")
      refute has_element?(view, "#notice-#{request.id}")
      view |> element("#open-#{request.id}") |> render_click()
      assert has_element?(view, "#notice-#{request.id}", "No terminal is attached")
      assert has_element?(view, "#notice-#{request.id}.bb-status-info")

      assert has_element?(
               view,
               ~s(#attach-#{request.id}[phx-hook=CopyField] input[value*="attach -t"])
             )

      refute has_element?(view, "#copy-session-#{request.id}")
      assert Requests.get(request.id).state == "pending"

      render_click(view, "open-request-drawer")
      view |> element("#drawer-open-#{request.id}") |> render_click()
      assert has_element?(view, "#drawer-notice-#{request.id}", "No terminal is attached")
      refute has_element?(view, "#drawer-copy-session-#{request.id}")

      old = System.get_env("PREVIEW")
      System.put_env("PREVIEW", "1")

      on_exit(fn ->
        if old, do: System.put_env("PREVIEW", old), else: System.delete_env("PREVIEW")
      end)

      for prefix <- ["", "drawer-"] do
        view |> element("##{prefix}card-focus-#{request.id}") |> render_click()

        assert has_element?(
                 view,
                 "##{prefix}card-focus-info-#{request.id}",
                 "tmux does not answer"
               )

        refute has_element?(view, "##{prefix}notice-#{request.id}")
      end
    end

    test "choosing an option on the card answers the pane; a changed pane refuses", %{
      conn: conn,
      sessions: sessions
    } do
      {session, received} = Foreman.ScratchPrompt.start(sessions["s-2"])

      ask = fn tool ->
        {:ok, request} =
          Requests.ask({"sample", "s-2"}, "session_waiting", %{
            "session" => session.session_id,
            "facts" => %{
              "reason" => "input",
              "tool" => tool,
              "tool_name" => "AskUserQuestion",
              "questions" => [Foreman.ScratchPrompt.question()]
            }
          })

        request
      end

      request = ask.("q-1")
      {:ok, view, _} = live(conn, "/needs-you")

      view
      |> form("#answer-#{request.id}")
      |> put_submitter("#answer-#{request.id}-0")
      |> render_submit()

      assert Foreman.ScratchPrompt.eventually(fn ->
               Foreman.ScratchPrompt.received(received) == "1"
             end)

      assert Requests.get(request.id).state == "answered"
      refute has_element?(view, "#pending-requests #request-#{request.id}")

      stale = ask.("q-2")
      send(view.pid, :reconcile)

      view
      |> form("#answer-#{stale.id}")
      |> put_submitter("#answer-#{stale.id}-1")
      |> render_submit()

      assert has_element?(view, "#notice-#{stale.id}", "no longer on screen")
      assert has_element?(view, "#open-#{stale.id}")
      assert Requests.get(stale.id).state == "pending"
      assert Foreman.ScratchPrompt.received(received) == "1"
    end

    defp chat_question(session, ticket) do
      {:ok, request} =
        Requests.ask({"sample", ticket}, "session_waiting", %{
          "session" => session.session_id,
          "facts" => %{"reason" => "question", "question" => "Tests pass.\nShall I commit it?"}
        })

      request
    end

    test "a chat question card shows the question, Open session and a Reply box", %{
      conn: conn,
      sessions: sessions
    } do
      request = chat_question(sessions["s-1"], "s-1")
      {:ok, view, _} = live(conn, "/needs-you")
      render_click(view, "open-request-drawer")

      for prefix <- ["", "drawer-"] do
        card = "##{prefix}request-#{request.id}"
        assert has_element?(view, "#{card} h2", "Planning session")
        assert has_element?(view, card, "Question")
        assert has_element?(view, "##{prefix}chat-question-#{request.id}", "Shall I commit it?")

        assert has_element?(
                 view,
                 "##{prefix}reply-#{request.id} ##{prefix}reply-text-#{request.id}"
               )

        assert has_element?(view, "##{prefix}reply-send-#{request.id}", "Reply")
        assert has_element?(view, "##{prefix}open-#{request.id}", "Open session")
        refute has_element?(view, "##{prefix}answer-#{request.id}")
        refute has_element?(view, "#{card} code")
      end
    end

    test "Reply types into an idle pane and answers the card", %{
      conn: conn,
      sessions: sessions
    } do
      {session, received} = Foreman.ScratchPrompt.start_chat(sessions["s-1"], :idle)
      request = chat_question(session, "s-1")
      {:ok, view, _} = live(conn, "/needs-you")

      view
      |> form("#reply-#{request.id}", %{"reply" => %{"text" => "yes, commit"}})
      |> render_submit()

      assert Foreman.ScratchPrompt.eventually(fn ->
               Foreman.ScratchPrompt.received(received) == "yes, commit\r"
             end)

      assert Requests.get(request.id).state == "answered"
      refute has_element?(view, "#pending-requests #request-#{request.id}")
    end

    test "Reply on a busy pane types nothing and keeps the card with Open session", %{
      conn: conn,
      sessions: sessions
    } do
      {session, received} = Foreman.ScratchPrompt.start_chat(sessions["s-2"], :busy)
      request = chat_question(session, "s-2")
      {:ok, view, _} = live(conn, "/needs-you")

      view
      |> form("#reply-#{request.id}", %{"reply" => %{"text" => "yes"}})
      |> render_submit()

      assert has_element?(view, "#notice-#{request.id}", "not at its prompt")
      assert has_element?(view, "#open-#{request.id}")
      assert has_element?(view, "#reply-text-#{request.id}")
      assert Requests.get(request.id).state == "pending"
      assert Foreman.ScratchPrompt.received(received) == ""

      render_click(view, "open-request-drawer")

      view
      |> form("#drawer-reply-#{request.id}", %{"reply" => %{"text" => "yes"}})
      |> render_submit()

      assert has_element?(view, "#drawer-notice-#{request.id}", "not at its prompt")
    end

    test "a new question card reaches the browser notification snapshot", %{
      conn: conn,
      sessions: sessions
    } do
      {:ok, view, _} = live(conn, "/")
      assert_push_event(view, "notification_snapshot", %{requests: before})
      request = chat_question(sessions["s-1"], "s-1")
      send(view.pid, :request_count_tick)
      render(view)
      id = request.id

      refute Enum.any?(before, &(&1.id == id))
      assert %{id: id, kind: "session_waiting", ticket: "s-1"} in next_snapshot(view, id)
    end

    # Mount and params each push a snapshot; take the first that has the request.
    defp next_snapshot(view, id, attempts \\ 5) do
      assert_push_event(view, "notification_snapshot", %{requests: requests})

      if attempts > 1 and not Enum.any?(requests, &(&1.id == id)),
        do: next_snapshot(view, id, attempts - 1),
        else: requests
    end
  end

  test "shared shell reconciles notification candidates without request facts", %{
    conn: conn,
    request: request
  } do
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#browser-notifications[phx-update=ignore]")
    assert has_element?(view, "#enable-notifications[hidden]")
    send(view.pid, :request_count_tick)
    render(view)

    id = request.id

    assert_push_event(view, "notification_snapshot", %{
      requests: [%{id: ^id, kind: "decision", ticket: "s-1"}]
    })

    Requests.resolve(request.id, :decline, %{})
    send(view.pid, :request_count_tick)
    render(view)
    assert_push_event(view, "notification_snapshot", %{requests: []})
    refute has_element?(view, "#needs-you-count")
  end

  test "answer records free text and updates live count in two tabs", %{
    conn: conn,
    request: request
  } do
    {:ok, view, _} = live(conn, "/needs-you")
    {:ok, other, _} = live(conn, "/")
    assert has_element?(view, "#pending-requests #request-#{request.id}")
    assert has_element?(view, "#request-#{request.id} [data-recommended=true]")
    assert has_element?(other, "#needs-you-count", "1")

    view
    |> form("#decision-#{request.id}", decision: %{note: "A different layout"})
    |> render_submit(%{"action" => "answer"})

    assert Requests.get(request.id).outcome == %{"answer" => "A different layout"}
    refute has_element?(view, "#recent-requests p.text-foreground-softer", "A different layout")
    refute has_element?(view, "#pending-requests #request-#{request.id}")
    send(other.pid, {:notification, :foreman_events, %{"kind" => "requests_changed"}})
    refute has_element?(other, "#needs-you-count")
    assert page_title(view) == "foreman"
  end

  test "decline note reaches the stored outcome and never creates a job", %{
    conn: conn,
    request: request
  } do
    {:ok, view, _} = live(conn, "/needs-you")
    assert page_title(view) == "(1) foreman"

    view
    |> form("#decision-#{request.id}", decision: %{note: "Not now"})
    |> render_submit(%{"action" => "decline"})

    assert %{state: "declined", note: "Not now"} = Requests.get(request.id)
    assert has_element?(view, "#recent-outcomes:not([open])")
    assert Foreman.Repo.aggregate(Oban.Job, :count) == 0
  end

  test "Recent outcomes keeps its open state across page updates", %{conn: conn} do
    {:ok, view, _} = live(conn, "/needs-you")
    # The browser owns the details element's open attribute; server patches must not reset it.
    assert has_element?(
             view,
             ~s(#recent-outcomes[phx-mounted*="ignore_attrs"][phx-mounted*="open"])
           )
  end

  test "one Note field supplies both actions and an option answer retains its note", %{
    conn: conn,
    request: request
  } do
    {:ok, view, _} = live(conn, "/needs-you")
    assert has_element?(view, "#decision-#{request.id} textarea[name='decision[note]']")
    refute has_element?(view, "#decision-#{request.id} input[type=text]")
    refute has_element?(view, "#request-#{request.id} textarea[name='decision[answer]']")
    assert has_element?(view, "#decision-actions-#{request.id} #submit-answer-#{request.id}")
    assert has_element?(view, "#decision-actions-#{request.id} #submit-decline-#{request.id}")

    view
    |> form("#decision-#{request.id}", decision: %{choice: "Compact", note: "Keep the shortcuts"})
    |> render_submit(%{"action" => "answer"})

    assert %{state: "answered", outcome: %{"answer" => "Compact"}, note: "Keep the shortcuts"} =
             Requests.get(request.id)
  end

  test "push card shows all named facts and decline does not enqueue", %{conn: conn} do
    request =
      Foreman.Repo.insert!(%Foreman.Requests.Request{
        repo_key: "sample",
        bead_id: "s-1",
        kind: "push",
        actor: "pi",
        state: "pending",
        facts: %{
          "remote" => "owner/repo",
          "worktree" => "/tmp/scratch",
          "local_branch" => "feature",
          "remote_branch" => "published",
          "expected_sha" => String.duplicate("a", 40)
        }
      })

    {:ok, view, _} = live(conn, "/needs-you")

    for text <- ["owner/repo", "/tmp/scratch", "feature", "published", String.duplicate("a", 40)] do
      assert has_element?(view, "#request-#{request.id} dd", text)
    end

    assert has_element?(view, "#request-#{request.id} dt", "Destination")
    assert has_element?(view, "#request-#{request.id} dd", "owner/repo → published")
    assert has_element?(view, "#submit-approve-#{request.id}", "Approve")

    view
    |> form("#push-#{request.id}", decision: %{note: "Not now"})
    |> render_submit(%{"action" => "decline"})

    assert %{state: "declined", note: "Not now"} = Requests.get(request.id)
    assert Foreman.Repo.aggregate(Oban.Job, :count) == 0
  end

  test "open PR card shows exact named facts and approval enqueues", %{conn: conn} do
    request =
      Foreman.Repo.insert!(%Foreman.Requests.Request{
        repo_key: "sample",
        bead_id: "s-1",
        kind: "open_pr",
        actor: "pi",
        state: "pending",
        facts: %{
          "remote" => "owner/repo",
          "head_branch" => "feature",
          "base_branch" => "main",
          "expected_sha" => String.duplicate("a", 40),
          "title" => "Exact title",
          "body" => "Exact body\nSecond line"
        }
      })

    {:ok, view, _} = live(conn, "/needs-you")

    for text <- [
          "owner/repo",
          "feature",
          "main",
          String.duplicate("a", 40),
          "Exact title",
          "Exact body"
        ] do
      assert has_element?(view, "#request-#{request.id} dd", text)
    end

    view
    |> form("#open_pr-#{request.id}", decision: %{note: "Open it"})
    |> render_submit(%{"action" => "approve"})

    assert %{state: "approved", note: "Open it"} = Requests.get(request.id)
    assert Foreman.Repo.aggregate(Oban.Job, :count) == 1
  end

  test "ticket Requests tab lists only that ticket's asks", %{conn: conn, request: request} do
    {:ok, view, _} = live(conn, "/?ticket=sample:s-1&tab=requests")
    assert has_element?(view, "#ticket-requests-tab[aria-selected=true]")
    assert has_element?(view, "#ticket-requests #ticket_requests-#{request.id}")
  end
end
