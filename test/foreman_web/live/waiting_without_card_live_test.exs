defmodule ForemanWeb.WaitingWithoutCardLiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Foreman.{Overlay, Repo, Requests}

  test "reports, human-merge PRs and shared decision blockers show their next steps", %{
    conn: conn
  } do
    Repo.insert_all("board_config", [
      %{
        id: 1,
        config: %{
          "merge_policy" => "human",
          "repos" => [
            %{"key" => "sample", "enabled" => true, "forge" => "github", "github" => "owner/repo"}
          ]
        },
        source: "test",
        discovered: [],
        loaded_at: DateTime.utc_now()
      }
    ])

    tickets = [
      %{id: "s-1", title: "Build report", issue_type: "task", status: "open"},
      %{id: "s-2", title: "Release", issue_type: "task", status: "open"},
      %{id: "s-3", title: "Choose a date", issue_type: "decision", status: "open"},
      %{
        id: "s-4",
        title: "Blocked work",
        issue_type: "task",
        status: "open",
        dependencies: [%{depends_on_id: "s-3", type: "blocks"}]
      }
    ]

    Foreman.Beads.Projection.replace("sample", Enum.map_join(tickets, "\n", &Jason.encode!/1))
    Overlay.apply_event({"sample", "s-1"}, {:dispatch, %{window: "build"}})
    Overlay.apply_event({"sample", "s-1"}, {:report, %{path: "/tmp/report.md"}})

    Foreman.Forge.Store.replace("sample", "owner/repo", %{
      "change_requests" => [
        %{
          "number" => 12,
          "state" => "open",
          "title" => "s-2 Release",
          "body" => "s-2",
          "url" => "https://github.com/owner/repo/pull/12"
        }
      ]
    })

    {:ok, view, _} = live(conn, "/needs-you")

    assert has_element?(
             view,
             "#waiting-without-card a[href='/needs-you?ticket=sample%3As-1']",
             "Review the report"
           )

    assert has_element?(
             view,
             "#waiting-without-card a[href='https://github.com/owner/repo/pull/12']",
             "Review and merge on GitHub"
           )

    assert has_element?(
             view,
             "#waiting-without-card a[href='/needs-you?ticket=sample%3As-3']",
             "Answer the decision"
           )

    assert has_element?(view, "#waiting-without-card p", "Blocks s-4")

    view
    |> element("#waiting-without-card a[href='/needs-you?ticket=sample%3As-3']")
    |> render_click()

    assert_patch(view, "/needs-you?ticket=sample%3As-3")
    assert has_element?(view, "#card-panel", "Choose a date")
  end

  test "waiting section links work and refreshes when a card covers it", %{conn: conn} do
    Repo.insert_all("board_config", [
      %{
        id: 1,
        config: %{"repos" => [%{"key" => "sample", "enabled" => true, "forge" => "github"}]},
        source: "test",
        discovered: [],
        loaded_at: DateTime.utc_now()
      }
    ])

    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "s-1", title: "Change", issue_type: "task", status: "open"})
    )

    Overlay.apply_event({"sample", "s-1"}, {:commit, %{sha: "abc"}}, %{actor: "claude"})
    {:ok, view, _} = live(conn, "/needs-you")

    assert has_element?(
             view,
             "#waiting-without-card a[href='/needs-you?ticket=sample%3As-1']",
             "Request a push"
           )

    {:ok, r} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Push now?"})
      })

    send(view.pid, :reconcile)
    refute has_element?(view, "#waiting-without-card a")
    assert has_element?(view, "#waiting-without-card-empty", "No items")
    Requests.resolve(r.id, :wrong_question, %{"note" => "Use a push card"})
    send(view.pid, :reconcile)
    assert has_element?(view, "#waiting-without-card a", "Request a push")
    Overlay.apply_event({"sample", "s-1"}, :abandon)
    send(view.pid, :reconcile)
    refute has_element?(view, "#waiting-without-card a")
  end
end
