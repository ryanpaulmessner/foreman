defmodule ForemanWeb.RequestDrawerTest do
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
        "facts" =>
          Foreman.DecisionFacts.valid(%{
            "question" => "Which layout?",
            "options" => ["Wide", "Compact"]
          })
      })

    %{request: request}
  end

  test "drawer rows navigate to the selected card without answering", %{
    conn: conn,
    request: request
  } do
    {:ok, view, _} = live(conn, "/")
    view |> element("#needs-you-badge") |> render_click()
    refute has_element?(view, "#request-drawer form")
    assert has_element?(view, "#drawer-count", "1")
    assert has_element?(view, "#drawer-row-#{request.id}", "Which layout?")
    assert has_element?(view, "#drawer-row-#{request.id} time[title]")

    {:error, {:live_redirect, %{to: path}}} =
      view |> element("#drawer-open-#{request.id}") |> render_click()

    assert path == "/needs-you?card=#{request.id}"
    {:ok, landed, _} = live(conn, path)
    assert has_element?(landed, "#card-open-#{request.id}")
    assert has_element?(landed, "#needs-you-badge[aria-expanded=false]")
    assert Requests.get(request.id).state == "pending"
  end

  test "drawer answer uses the page resolution and stale page decline cannot overwrite it", %{
    conn: conn,
    request: request
  } do
    {:ok, page, _} = live(conn, "/needs-you")
    {:ok, drawer, _} = live(conn, "/settings")
    render_click(drawer, "open-request-drawer")

    {:error, {:live_redirect, %{to: path}}} =
      drawer |> element("#drawer-open-#{request.id}") |> render_click()

    {:ok, drawer, _} = live(conn, path)

    drawer
    |> form("#decision-#{request.id}",
      decision: %{choice: "Compact", note: "Keep shortcuts"}
    )
    |> render_submit(%{"action" => "answer"})

    assert %{state: "answered", note: "Keep shortcuts", outcome: %{"answer" => "Compact"}} =
             Requests.get(request.id)

    render_submit(page, "resolve", %{
      "id" => request.id,
      "decision" => %{"note" => "stale"},
      "action" => "decline"
    })

    assert %{state: "answered", note: "Keep shortcuts"} = Requests.get(request.id)
    refute has_element?(drawer, "#pending-requests #request-#{request.id}")
    assert Foreman.Repo.aggregate(Oban.Job, :count) == 0
  end

  test "invalid answer after drawer navigation stays on the open card", %{
    conn: conn,
    request: request
  } do
    {:ok, view, _} = live(conn, "/settings")
    render_click(view, "open-request-drawer")

    {:error, {:live_redirect, %{to: path}}} =
      view |> element("#drawer-open-#{request.id}") |> render_click()

    {:ok, view, _} = live(conn, path)

    view
    |> form("#decision-#{request.id}", decision: %{note: ""})
    |> render_submit(%{"action" => "answer"})

    assert has_element?(view, "#card-error-#{request.id}[role=alert]")
    assert Requests.get(request.id).state == "pending"
    assert has_element?(view, "#card-open-#{request.id}")

    view
    |> form("#decision-#{request.id}", decision: %{note: "Not now"})
    |> render_submit(%{"action" => "decline"})

    refute has_element?(view, "#drawer-error")
    assert %{state: "declined", note: "Not now"} = Requests.get(request.id)
  end

  test "page and drawer approval enqueue only one push job", %{conn: conn} do
    path = Path.join(System.tmp_dir!(), "drawer-refs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(path, ".git/refs/heads"))
    File.write!(Path.join(path, ".git/refs/heads/main"), String.duplicate("a", 40) <> "\n")
    on_exit(fn -> File.rm_rf!(path) end)

    request =
      Foreman.Repo.insert!(%Foreman.Requests.Request{
        repo_key: "sample",
        bead_id: "s-1",
        kind: "push",
        actor: "pi",
        state: "pending",
        facts: %{
          "remote" => "owner/repo",
          "worktree" => path,
          "local_branch" => "main",
          "remote_branch" => "feature",
          "expected_sha" => String.duplicate("a", 40)
        }
      })

    {:ok, page, _} = live(conn, "/needs-you")
    {:ok, drawer, _} = live(conn, "/")
    render_click(drawer, "open-request-drawer")

    {:error, {:live_redirect, %{to: path}}} =
      drawer |> element("#drawer-open-#{request.id}") |> render_click()

    {:ok, drawer, _} = live(conn, path)

    drawer
    |> form("#push-#{request.id}", decision: %{note: "Publish"})
    |> render_submit(%{"action" => "approve"})

    assert %{state: "approved", note: "Publish"} = Requests.get(request.id)

    render_submit(page, "resolve", %{
      "id" => request.id,
      "decision" => %{"note" => "Again"},
      "action" => "approve"
    })

    assert %{state: "approved", note: "Publish"} = Requests.get(request.id)
    assert Foreman.Repo.aggregate(Oban.Job, :count) == 1
  end

  for action <- ["approve", "decline"] do
    test "open PR drawer #{action} shares the page's action card", %{conn: conn} do
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

      {:ok, view, _} = live(conn, "/needs-you?card=#{request.id}")
      render_click(view, "open-request-drawer")

      open_from_drawer(view, request.id)
      assert has_element?(view, "#request-#{request.id} dd", "Exact title")
      assert has_element?(view, "#request-#{request.id} dd", "Exact body")

      view
      |> form("#open_pr-#{request.id}", decision: %{note: "Reviewed"})
      |> render_submit(%{"action" => unquote(action)})

      assert Requests.get(request.id).state ==
               if(unquote(action) == "approve", do: "approved", else: "declined")

      assert Requests.get(request.id).note == "Reviewed"

      assert Foreman.Repo.aggregate(Oban.Job, :count) ==
               if(unquote(action) == "approve", do: 1, else: 0)

      refute has_element?(view, "#pending-requests #request-#{request.id}")
    end
  end

  test "drawer Open patches Needs you and keeps the panel and typed input", %{
    conn: conn,
    request: request
  } do
    {:ok, other} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Another?"})
      })

    {:ok, view, _} = live(conn, "/needs-you?card=#{request.id}&ticket=sample%3As-1")

    view
    |> form("#decision-#{request.id}", decision: %{note: "Keep this note"})
    |> render_change()

    open_from_drawer(view, other.id)
    assert has_element?(view, "#card-open-#{other.id}")
    assert has_element?(view, "#card-panel #ticket-title")
    open_from_drawer(view, request.id)
    assert has_element?(view, "#card-text-#{request.id}", "Keep this note")
  end

  test "a drawer row that closed elsewhere lands on the stale-card notice", %{
    conn: conn,
    request: request
  } do
    {:ok, view, _} = live(conn, "/")
    view |> element("#needs-you-badge") |> render_click()
    Requests.resolve(request.id, :decline, %{})

    {:error, {:live_redirect, %{to: path}}} =
      view |> element("#drawer-open-#{request.id}") |> render_click()

    {:ok, landed, _} = live(conn, path)
    assert has_element?(landed, "#needs-you-badge[aria-expanded=false]")
    refute has_element?(landed, "#card-open-#{request.id}")
    assert has_element?(landed, "#cards-notice", "That card is no longer open")
  end

  test "same-page drawer Open checks a card that closed since the last poll", %{
    conn: conn,
    request: request
  } do
    {:ok, view, _} = live(conn, "/needs-you")
    view |> element("#needs-you-badge") |> render_click()
    Requests.resolve(request.id, :decline, %{})
    view |> element("#drawer-open-#{request.id}") |> render_click()
    refute has_element?(view, "#card-open-#{request.id}")
    assert has_element?(view, "#cards-notice", "That card is no longer open")
    assert has_element?(view, "#needs-you-badge[aria-expanded=false]")
  end

  test "empty drawer has zero count and no rows", %{conn: conn, request: request} do
    Requests.resolve(request.id, :decline, %{})
    {:ok, view, _} = live(conn, "/")
    view |> element("#needs-you-badge") |> render_click()
    assert has_element?(view, "#drawer-count", "0")
    assert has_element?(view, "#drawer-empty", "No pending requests")
    refute has_element?(view, "#drawer-requests [id^=drawer-row-]")
  end

  test "seven pending cards each have one navigation row", %{conn: conn} do
    for i <- 1..6 do
      Requests.ask({"sample", "s-1"}, "decision", %{
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Question #{i}?"})
      })
    end

    {:ok, view, _} = live(conn, "/needs-you")
    view |> element("#needs-you-badge") |> render_click()
    assert has_element?(view, "#drawer-count", "7")

    assert view
           |> element("#drawer-requests")
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("[id^=drawer-row-]")
           |> Enum.count() == 7

    refute has_element?(view, "#request-drawer form")
  end

  test "open drawer reconciles only pending requests", %{conn: conn, request: request} do
    {:ok, view, _} = live(conn, "/")
    render_click(view, "open-request-drawer")

    {:ok, other} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "actor" => "pi",
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Another?"})
      })

    Requests.resolve(request.id, :decline, %{})
    send(view.pid, :request_count_tick)
    assert has_element?(view, "#drawer-row-#{other.id}")
    refute has_element?(view, "#drawer-row-#{request.id}")
    render_click(view, "close-request-drawer")
    assert has_element?(view, "#needs-you-badge[aria-expanded=false]")
  end

  test "badge opens pending requests without navigating on every page", %{
    conn: conn,
    request: request
  } do
    for path <- [
          "/",
          "/pull-requests",
          "/settings",
          "/documents/sample",
          "/needs-you",
          "/epics/sample/missing"
        ] do
      {:ok, view, _} = live(conn, path)
      assert has_element?(view, "#needs-you-badge[phx-click='open-request-drawer']")
      view |> element("#needs-you-badge") |> render_click()
      assert has_element?(view, "#drawer-requests #drawer-row-#{request.id}")
      refute has_element?(view, "#request-drawer form")
    end
  end
end
