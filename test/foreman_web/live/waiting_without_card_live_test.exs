defmodule ForemanWeb.WaitingWithoutCardLiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Foreman.{CloseOutNags, Overlay, Repo, Requests}

  setup do
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
      },
      %{id: "s-5", title: "Branch work", issue_type: "task", status: "open"}
    ]

    Foreman.Beads.Projection.replace("sample", Enum.map_join(tickets, "\n", &Jason.encode!/1))
    Overlay.apply_event({"sample", "s-1"}, {:dispatch, %{window: "build"}})
    Overlay.apply_event({"sample", "s-1"}, {:report, %{path: "/tmp/report.md"}})
    Overlay.apply_event({"sample", "s-5"}, {:dispatch, %{window: "b5", branch: "feat/five"}})
    :ok
  end

  defp forge(prs),
    do: Foreman.Forge.Store.replace("sample", "owner/repo", %{"change_requests" => prs})

  defp pr(number, title, branch, opts \\ []) do
    %{
      "number" => number,
      "state" => "open",
      "title" => title,
      "body" => Keyword.get(opts, :body, ""),
      "source_branch" => branch,
      "url" => "https://github.com/owner/repo/pull/#{number}",
      "created_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -2 * 3600))
    }
  end

  test "Needs you lists only PRs to merge, each with an Open on GitHub button", %{conn: conn} do
    forge([pr(12, "s-2 Release", "release", body: "s-2"), pr(463, "Five", "feat/five")])
    {:ok, view, _} = live(conn, "/needs-you")

    assert has_element?(view, "#merge-list-heading", "Pull requests for you to merge")
    assert has_element?(view, "#merge-list-heading", "2")

    button =
      "#merge-list a#merge-open-sample-12[href='https://github.com/owner/repo/pull/12'][target='_blank'][rel~='noopener']"

    assert has_element?(view, button, "Open on GitHub")
    assert has_element?(view, "#merge-list a#merge-open-sample-463", "Open on GitHub")
    assert has_element?(view, "#merge-list li", "s-5")
    assert has_element?(view, "#merge-list li", "#463")
    assert has_element?(view, "#merge-list li time[title]", "2 h ago")

    # Every link in a row is its action; stuck agent work and decisions are not listed.
    rows = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#merge-list a")
    assert Enum.count(rows) == 2
    refute render(view) =~ "Review the report"
    refute render(view) =~ "Choose a date"
    refute has_element?(view, "#waiting-without-card")
  end

  test "the section is hidden when empty and refreshes when a card covers a PR", %{conn: conn} do
    {:ok, view, _} = live(conn, "/needs-you")
    refute has_element?(view, "#merge-list-section")

    forge([pr(12, "s-2 Release", "release", body: "s-2")])
    send(view.pid, :reconcile)
    assert has_element?(view, "#merge-list a", "Open on GitHub")

    {:ok, r} =
      Requests.ask({"sample", "s-2"}, "decision", %{
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Merge now?"})
      })

    send(view.pid, :reconcile)
    refute has_element?(view, "#merge-list-section")
    Requests.resolve(r.id, :wrong_question, %{"note" => "Merge on GitHub"})
    send(view.pid, :reconcile)
    assert has_element?(view, "#merge-list-heading", "1")
  end

  test "stuck agent work is not on Needs you; its notes show on the ticket history", %{conn: conn} do
    CloseOutNags.run(
      now: DateTime.add(DateTime.utc_now(), 31 * 60, :second),
      deliver: fn _, _ -> flunk("no owner was recorded") end
    )

    {:ok, view, _} = live(conn, "/needs-you?ticket=sample%3As-1&tab=history")
    refute has_element?(view, "#merge-list-section")
    assert has_element?(view, "#ticket-history article", "note_to_coordinator")
    assert has_element?(view, "#ticket-history [data-history-outcome='not-delivered']")
    assert has_element?(view, "#ticket-history article", "no coordinator recorded on dispatch")
    assert has_element?(view, "#ticket-history article", "foreman review s-1")
  end
end
