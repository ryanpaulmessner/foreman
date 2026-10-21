defmodule ForemanWeb.WeekLiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    {:ok, config} =
      Foreman.Config.parse_layers([{"defaults", File.read!("priv/foreman.defaults.toml")}])

    config =
      Map.put(config, "repos", [
        %{
          "key" => "work",
          "path" => "/tmp/week-work",
          "tickets" => "files",
          "enabled" => true,
          "forge" => "github",
          "github" => "org/repo"
        }
      ])

    Foreman.Repo.insert_all("board_config", [
      %{
        id: 1,
        config: config,
        source: "/tmp/settings",
        discovered: [],
        loaded_at: DateTime.utc_now()
      }
    ])

    :ok
  end

  test "kind sections are ordered, empty ones hidden, and ticket details expand", %{conn: conn} do
    today =
      DateTime.utc_now()
      |> DateTime.shift_zone!("America/Chicago")
      |> DateTime.to_date()
      |> Date.to_iso8601()

    rows =
      for {id, kind} <- [{"a", "feature"}, {"b", "break_fix"}, {"c", "internal"}] do
        %{
          id: id,
          title: "Ticket #{id}",
          issue_type: "task",
          status: "open",
          kind: kind,
          notes: "- #{today}: worked",
          dependencies: []
        }
      end

    Foreman.Beads.Projection.replace("work", Enum.map_join(rows, "\n", &Jason.encode!/1))
    {:ok, view, _} = live(conn, "/week")
    assert has_element?(view, "#week-feature + #week-break_fix + #week-internal")
    refute has_element?(view, "#week-mapping")
    assert has_element?(view, "#this-week-link[aria-current=page]")
    refute has_element?(view, "#week-details-work-a")
    view |> element("#week-toggle-work-a") |> render_click()
    assert has_element?(view, "#week-details-work-a")
    assert has_element?(view, "#week-file-work-a[href='/documents/work?path=tickets%2Fa.md']")
    view |> element("#week-toggle-work-a") |> render_click()
    refute has_element?(view, "#week-details-work-a")
  end

  test "rows show progress, linked PRs, local activity day and missing staging details", %{
    conn: conn
  } do
    today = DateTime.utc_now() |> DateTime.shift_zone!("America/Chicago") |> DateTime.to_date()

    Foreman.Beads.Projection.replace(
      "work",
      Jason.encode!(%{
        id: "rs-one",
        title: "One",
        issue_type: "task",
        status: "open",
        notes: "- #{today}: worked",
        dependencies: []
      })
    )

    Foreman.Week.PrLinks.record("work", "org/repo", [
      %{
        "number" => 12,
        "title" => "rs-one",
        "body" => "",
        "source_branch" => "rs-one",
        "target_branch" => "staging",
        "head_sha" => String.duplicate("a", 40),
        "state" => "merged",
        "url" => "https://github.com/org/repo/pull/12"
      }
    ])

    {:ok, unchecked_view, _} = live(conn, "/week")

    assert has_element?(
             unchecked_view,
             "#week-progress-work-rs-one [aria-current=step]",
             "Merged, checking…"
           )

    Foreman.Repo.update_all("week_pr_links",
      set: [in_production: false, in_staging: false, checked_at: DateTime.utc_now()]
    )

    {:ok, view, _} = live(conn, "/week")
    assert has_element?(view, "#week-progress-work-rs-one [aria-current=step]", "On staging")
    assert has_element?(view, "#week-progress-work-rs-one .dark\\:bg-blue-950")

    assert has_element?(
             view,
             "#week-pr-work-rs-one-12[href='https://github.com/org/repo/pull/12']",
             "#12"
           )

    assert has_element?(view, "#week-day-work-rs-one[title]", "Today")
    view |> element("#week-toggle-work-rs-one") |> render_click()
    assert has_element?(view, "#week-missing-staging-work-rs-one", "not found in staging")
  end

  test "waiting rows keep their stage label and terminal rows show their outcome", %{conn: conn} do
    today = DateTime.utc_now() |> DateTime.shift_zone!("America/Chicago") |> DateTime.to_date()

    rows =
      for {id, status, reason} <- [
            {"rs-open", "in_progress", nil},
            {"rs-done", "closed", nil},
            {"rs-closed", "closed", "won't do"}
          ],
          do: %{
            id: id,
            title: id,
            status: status,
            close_reason: reason,
            issue_type: "task",
            notes: "- #{today}: worked",
            dependencies: []
          }

    Foreman.Beads.Projection.replace("work", Enum.map_join(rows, "\n", &Jason.encode!/1))

    Foreman.Week.PrLinks.record("work", "org/repo", [
      %{
        "number" => 14,
        "title" => "rs-open",
        "body" => "",
        "source_branch" => "rs-open",
        "head_sha" => String.duplicate("a", 40),
        "state" => "open",
        "url" => "https://github.com/org/repo/pull/14"
      }
    ])

    {:ok, view, _} = live(conn, "/week")
    assert has_element?(view, "#week-progress-work-rs-open [aria-current=step]", "PR open")
    assert has_element?(view, "#week-status-work-rs-open", "Waiting on others")
    assert has_element?(view, "#week-terminal-work-rs-done", "Done")
    assert has_element?(view, "#week-terminal-work-rs-closed", "Closed, not done")
    refute has_element?(view, "#week-progress-work-rs-done")
  end

  test "empty week has a clear empty state", %{conn: conn} do
    {:ok, view, _} = live(conn, "/week")
    assert has_element?(view, "#week-empty")
  end
end
