defmodule ForemanWeb.NeedsYouLiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Foreman.Requests

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
          "recommendation" => "Compact"
        }
      })

    %{request: request}
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
           })}
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
      assert has_element?(view, "#attach-#{request.id}", "attach -t")
      assert Requests.get(request.id).state == "pending"

      render_click(view, "open-request-drawer")
      view |> element("#drawer-open-#{request.id}") |> render_click()
      assert has_element?(view, "#drawer-notice-#{request.id}", "No terminal is attached")
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

  test "one Note field supplies both actions and an option answer retains its note", %{
    conn: conn,
    request: request
  } do
    {:ok, view, _} = live(conn, "/needs-you")
    assert has_element?(view, "#decision-#{request.id} textarea[name='decision[note]']")
    refute has_element?(view, "#request-#{request.id} input[type=text]")
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
