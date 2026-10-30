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

  test "drawer answer uses the page resolution and stale page decline cannot overwrite it", %{
    conn: conn,
    request: request
  } do
    {:ok, page, _} = live(conn, "/needs-you")
    {:ok, drawer, _} = live(conn, "/settings")
    render_click(drawer, "open-request-drawer")

    drawer
    |> form("#drawer-decision-#{request.id}",
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
    refute has_element?(drawer, "#drawer-request-#{request.id}")
    assert Foreman.Repo.aggregate(Oban.Job, :count) == 0
  end

  test "invalid drawer answer shows an error inside the sheet and retains the request", %{
    conn: conn,
    request: request
  } do
    {:ok, view, _} = live(conn, "/settings")
    render_click(view, "open-request-drawer")

    view
    |> form("#drawer-decision-#{request.id}", decision: %{note: ""})
    |> render_submit(%{"action" => "answer"})

    assert has_element?(view, "#request-drawer #drawer-error[role=alert]", "Request not updated")
    assert Requests.get(request.id).state == "pending"
    assert has_element?(view, "#drawer-request-#{request.id}")

    view
    |> form("#drawer-decision-#{request.id}", decision: %{note: "Not now"})
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

    drawer
    |> form("#drawer-push-#{request.id}", decision: %{note: "Publish"})
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

      {:ok, view, _} = live(conn, "/needs-you")
      render_click(view, "open-request-drawer")

      for prefix <- ["", "drawer-"] do
        assert has_element?(view, "##{prefix}request-#{request.id} dd", "Exact title")
        assert has_element?(view, "##{prefix}request-#{request.id} dd", "Exact body")
      end

      view
      |> form("#drawer-open_pr-#{request.id}", decision: %{note: "Reviewed"})
      |> render_submit(%{"action" => unquote(action)})

      assert Requests.get(request.id).state ==
               if(unquote(action) == "approve", do: "approved", else: "declined")

      assert Requests.get(request.id).note == "Reviewed"

      assert Foreman.Repo.aggregate(Oban.Job, :count) ==
               if(unquote(action) == "approve", do: 1, else: 0)

      refute has_element?(view, "#drawer-request-#{request.id}")
    end
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
    assert has_element?(view, "#drawer-request-#{other.id}")
    refute has_element?(view, "#drawer-request-#{request.id}")
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
      assert has_element?(view, "#drawer-requests #drawer-request-#{request.id}")
      assert has_element?(view, "#drawer-decision-#{request.id}")
    end
  end
end
