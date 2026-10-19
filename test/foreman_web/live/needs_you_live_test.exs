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

  test "waiting cards share attach and usage-only Continue on page and drawer", %{conn: conn} do
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
    assert has_element?(view, "#request-#{request.id} code", "tmux -L")
    assert has_element?(view, "#continue-#{request.id}", "Continue")
    assert has_element?(view, "#request-#{request.id}", "Codex")
    assert has_element?(view, "#request-#{request.id}", "14:00")
    refute has_element?(view, "#submit-approve-#{request.id}")
    render_click(view, "open-request-drawer")
    assert has_element?(view, "#drawer-continue-#{request.id}")

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
