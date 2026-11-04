defmodule ForemanWeb.PullRequestsLiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    {:ok, config} =
      Foreman.Config.parse_layers([{"defaults", File.read!("priv/foreman.defaults.toml")}])

    repos = [
      %{
        "key" => "sample",
        "path" => "/tmp/sample",
        "enabled" => true,
        "forge" => "github",
        "github" => "rpmessner/form-engine"
      },
      %{"key" => "local", "path" => "/tmp/local", "enabled" => true, "forge" => "none"}
    ]

    Foreman.Repo.insert_all("board_config", [
      %{
        id: 1,
        config: Map.put(config, "repos", repos),
        source: "test",
        discovered: [],
        loaded_at: DateTime.utc_now()
      }
    ])

    beads = [
      %{id: "fe-813", title: "Looper", status: "open", issue_type: "epic"},
      %{
        id: "fe-813.2",
        title: "Meter",
        status: "open",
        issue_type: "task",
        dependencies: [%{depends_on_id: "fe-813", type: "parent-child"}]
      },
      %{
        id: "fe-813.3",
        title: "Scheduler",
        status: "open",
        issue_type: "task",
        dependencies: [%{depends_on_id: "fe-813", type: "parent-child"}]
      }
    ]

    Foreman.Beads.Projection.replace("sample", Enum.map_join(beads, "\n", &Jason.encode!/1))

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, File.read!("test/fixtures/forge/form-engine.json") |> Jason.decode!())
    end)

    {:ok, snapshot} =
      Foreman.Forge.GitHub.list("rpmessner/form-engine",
        token: "test",
        plug: {Req.Test, __MODULE__}
      )

    Foreman.Forge.Store.replace("sample", "rpmessner/form-engine", snapshot)
    :ok
  end

  for entry <- [:page, :drawer] do
    test "#{entry} approval opens existing confirmation without enqueueing; cancel keeps ask pending",
         %{conn: conn} do
      stored = Foreman.Forge.Store.get("sample")

      snapshot =
        put_in(stored.snapshot, ["change_requests", Access.at(0), "mergeable"], "mergeable")

      Foreman.Forge.Store.replace("sample", stored.remote, snapshot)

      {:ok, request} =
        Foreman.Requests.ask({"sample", "fe-813.3"}, "merge", %{
          "facts" => %{
            "number" => 5,
            "expected_sha" => hd(snapshot["change_requests"])["head_sha"]
          }
        })

      {:ok, inbox, _} =
        live(conn, if(unquote(entry) == :drawer, do: "/settings", else: "/needs-you"))

      inbox =
        if unquote(entry) == :drawer do
          render_click(inbox, "open-request-drawer")

          {:error, {:live_redirect, %{to: path}}} =
            inbox |> element("#drawer-open-#{request.id}") |> render_click()

          {:ok, landed, _} = live(conn, path)
          landed
        else
          inbox
        end

      prefix = ""
      assert has_element?(inbox, "##{prefix}request-#{request.id}", stored.remote)

      inbox
      |> form("##{prefix}merge-#{request.id}", decision: %{note: "Ready"})
      |> render_submit(%{"action" => "approve"})

      {path, _} = assert_redirect(inbox)
      refute URI.decode_query(URI.parse(path).query) |> Map.has_key?("note")
      {:ok, view, _} = live(conn, path)

      assert has_element?(
               view,
               "#merge-confirm[data-open=true]",
               "Retarget #6"
             )

      assert Foreman.Requests.get(request.id).state == "pending"
      assert Foreman.Repo.aggregate(Oban.Job, :count) == 0
      view |> element("#merge-confirm-cancel") |> render_click()
      assert_patch(view, "/pull-requests?project=sample")
      assert Foreman.Requests.get(request.id).state == "pending"
      {:ok, view, _} = live(conn, path)
      view |> element("#merge-confirm-submit") |> render_click()
      assert Foreman.Requests.get(request.id).state == "executing"
      assert Foreman.Requests.get(request.id).note == "Ready"
      assert_patch(view, "/pull-requests?project=sample")
      assert Foreman.Repo.aggregate(Oban.Job, :count) == 1
    end
  end

  test "sheet tabs preserve the PR page URL and refresh hidden streams", %{conn: conn} do
    {:ok, view, _} = live(conn, "/pull-requests?project=sample&ticket=sample:fe-813.2&tab=notes")
    assert has_element?(view, "#ticket-notes-tab[aria-selected=true]")
    Foreman.Overlay.apply_event({"sample", "fe-813.2"}, :abandon)
    Foreman.Overlay.apply_event({"sample", "fe-813.2"}, :revive)

    Foreman.Overlay.apply_event(
      {"sample", "fe-813.2"},
      {:dispatch, %{window: "%98", session: "pr_worker", harness: "pi"}}
    )

    send(view.pid, {:notification, :foreman_events, "sample/fe-813.2"})
    assert has_element?(view, "#ticket-sessions-panel[hidden]", "pr_worker")
    view |> element("#ticket-sessions-tab") |> render_click()
    assert_patch(view, "/pull-requests?project=sample&tab=sessions&ticket=sample%3Afe-813.2")
    assert has_element?(view, "#ticket-sessions-panel:not([hidden])", "pr_worker")
    render_patch(view, "/pull-requests?project=sample&ticket=sample:fe-813.2&tab=unknown")
    assert has_element?(view, "#ticket-overview-tab[aria-selected=true]")
    render_click(view, "close-ticket", %{"key" => "sample:fe-813.2"})
    assert_patch(view, "/pull-requests?project=sample")
  end

  test "stack links open the sheet; local repositories have no panel", %{conn: conn} do
    {:ok, view, _} = live(conn, "/pull-requests?project=sample")
    assert has_element?(view, "#pull-requests [data-number='5'] + [data-number='6']")
    assert has_element?(view, "#cr-sample-6 [data-parent='5']", "Waiting on #5")
    assert has_element?(view, "#merge-request-5")
    view |> element("#cr-sample-6 a[data-bead='fe-813.2']") |> render_click()
    assert_patch(view, "/pull-requests?project=sample&ticket=sample%3Afe-813.2")
    assert has_element?(view, "#ticket-sheet[data-open=true]")

    assert has_element?(
             view,
             "#ticket-crs a[href='https://github.com/rpmessner/form-engine/pull/6']"
           )

    render_patch(view, "/pull-requests?project=local")
    refute has_element?(view, "#forge-panel")
  end

  test "merge confirmation, job phases and observed close suggestion", %{conn: conn} do
    stored = Foreman.Forge.Store.get("sample")

    snapshot =
      put_in(stored.snapshot, ["change_requests", Access.at(0), "mergeable"], "mergeable")

    Foreman.Forge.Store.replace("sample", stored.remote, snapshot)
    fake = start_supervised!({Foreman.Forge.Fake, snapshot})
    {:ok, view, _} = live(conn, "/pull-requests?project=sample")
    view |> element("#merge-request-6") |> render_click()
    assert has_element?(view, "#merge-status", "Bottom of stack only")
    refute has_element?(view, "#merge-confirm[data-open=true]")
    view |> element("#merge-request-5") |> render_click()
    assert has_element?(view, "#merge-confirm[data-open=true]")

    assert has_element?(
             view,
             "#merge-confirm",
             snapshot["change_requests"] |> hd() |> Map.fetch!("head_sha")
           )

    assert has_element?(view, "#merge-confirm", "fe-813.3")
    assert has_element?(view, "#merge-confirm", "Retarget #6")
    view |> element("#merge-confirm-submit") |> render_click()
    assert has_element?(view, "#merge-status[data-state=merging]")
    row = Foreman.Merge.latest("sample")
    Foreman.Merge.MergeJob.run(row.id, Foreman.Forge.Fake, server: fake)
    send(view.pid, :reconcile)
    assert has_element?(view, "#merge-status[data-state=retargeting]")
    refute has_element?(view, "#retarget-offers")
    Foreman.Merge.RetargetJob.run(row.id, Foreman.Forge.Fake, server: fake)
    send(view.pid, :reconcile)
    assert has_element?(view, "#merge-status[data-state=merged]")
    assert Foreman.Overlay.get({"sample", "fe-813.3"}).stage == :pr_open
    {:ok, observed} = Foreman.Forge.Fake.list(stored.remote, server: fake)
    Foreman.Forge.Store.replace("sample", stored.remote, observed)
    render_patch(view, "/pull-requests?project=sample&ticket=sample%3Afe-813.3")
    assert has_element?(view, "#ticket-stage", "merged")
    assert has_element?(view, "#ticket-close-suggestion", "bd close fe-813.3")
  end

  test "Needs you merge card names the child and configured target", %{conn: conn} do
    stored = Foreman.Forge.Store.get("sample")

    config =
      put_in(
        Foreman.RuntimeState.config().config,
        ["repos", Access.at(0), "merge_base"],
        "staging"
      )

    Foreman.Repo.update_all("board_config", set: [config: config])

    snapshot =
      stored.snapshot
      |> put_in(["change_requests", Access.at(0), "mergeable"], "mergeable")
      |> put_in(["change_requests", Access.at(0), "target_branch"], "staging")

    Foreman.Forge.Store.replace("sample", stored.remote, snapshot)

    {:ok, request} =
      Foreman.Requests.ask({"sample", "fe-813.3"}, "merge", %{
        "facts" => %{"number" => 5, "expected_sha" => hd(snapshot["change_requests"])["head_sha"]}
      })

    {:ok, view, _} = live(conn, "/needs-you")

    assert has_element?(
             view,
             "#request-#{request.id}",
             "Retarget PR #6 to staging after the merge."
           )
  end

  test "a head observed after opening confirmation requires a fresh confirmation", %{conn: conn} do
    stored = Foreman.Forge.Store.get("sample")

    snapshot =
      put_in(stored.snapshot, ["change_requests", Access.at(0), "mergeable"], "mergeable")

    Foreman.Forge.Store.replace("sample", stored.remote, snapshot)
    {:ok, view, _} = live(conn, "/pull-requests?project=sample")
    view |> element("#merge-request-5") |> render_click()
    moved = put_in(snapshot, ["change_requests", Access.at(0), "head_sha"], "new-head")
    Foreman.Forge.Store.replace("sample", stored.remote, moved)
    view |> element("#merge-confirm-submit") |> render_click()
    assert has_element?(view, "#merge-confirm[data-open=true]", "Head moved")
    assert Foreman.Merge.latest("sample") == nil
  end

  test "repeated request exposes the durable failure, not a confirmation that cannot run", %{
    conn: conn
  } do
    stored = Foreman.Forge.Store.get("sample")

    snapshot =
      put_in(stored.snapshot, ["change_requests", Access.at(0), "mergeable"], "mergeable")

    Foreman.Forge.Store.replace("sample", stored.remote, snapshot)
    fake = start_supervised!({Foreman.Forge.Fake, Map.put(snapshot, "merge_error", true)})
    {:ok, view, _} = live(conn, "/pull-requests?project=sample")
    view |> element("#merge-request-5") |> render_click()
    view |> element("#merge-confirm-submit") |> render_click()
    row = Foreman.Merge.latest("sample")
    Foreman.Merge.MergeJob.run(row.id, Foreman.Forge.Fake, server: fake)
    send(view.pid, :reconcile)
    assert has_element?(view, "#merge-status[data-state=failed]")
    view |> element("#merge-request-5") |> render_click()
    refute has_element?(view, "#merge-confirm[data-open=true]")
    assert has_element?(view, "#merge-status[data-state=failed]")
  end

  test "initiatives count distinct open CRs across an epic's tickets", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "[data-bead='fe-813'] [data-cr-count='2']")
  end

  test "copy is limited to labels, controls and status with human timestamps", %{conn: conn} do
    {:ok, view, _} = live(conn, "/pull-requests?project=sample")
    refute has_element?(view, "main header p")
    refute has_element?(view, "#forge-panel > p")
    assert has_element?(view, "#forge-synced time[title][datetime]", "just now")
    time = DateTime.add(DateTime.utc_now(), -150)
    Foreman.Repo.update_all("forge_snapshots", set: [synced_at: time])
    send(view.pid, :reconcile)
    assert has_element?(view, "#forge-synced time", "2 min ago")
  end

  test "manual refresh reports completion and failure", %{conn: conn} do
    Foreman.Repo.update_all("forge_snapshots",
      set: [attempted_at: DateTime.add(DateTime.utc_now(), -121)]
    )

    {:ok, view, _} = live(conn, "/pull-requests?project=sample")
    view |> element("#forge-refresh") |> render_click()
    assert has_element?(view, "#flash-group", "Refreshing")
    row = Foreman.Forge.Store.get("sample")
    Foreman.Forge.Store.replace("sample", row.remote, row.snapshot)
    send(view.pid, :reconcile)
    assert has_element?(view, "#flash-group", "Updated")

    Foreman.Repo.update_all("forge_snapshots",
      set: [attempted_at: DateTime.add(DateTime.utc_now(), -121)]
    )

    send(view.pid, :reconcile)
    view |> element("#forge-refresh") |> render_click()
    assert has_element?(view, "#flash-group", "Refreshing")
    Foreman.Forge.Store.failed("sample", row.remote, :unavailable)
    send(view.pid, :reconcile)
    assert has_element?(view, "#flash-group", "Refresh failed")
    view |> element("#forge-refresh") |> render_click()
    assert has_element?(view, "#flash-group", "Refresh failed")
  end

  test "forge success and failure leave beads sidebar health unchanged", %{conn: conn} do
    Foreman.RuntimeState.record("sample", {:ok, :changed})
    before = Foreman.RuntimeState.repos() |> Enum.find(&(&1["key"] == "sample"))
    row = Foreman.Forge.Store.get("sample")
    Foreman.Forge.Store.failed("sample", row.remote, :unavailable)
    Foreman.Forge.Store.replace("sample", row.remote, row.snapshot)
    after_read = Foreman.RuntimeState.repos() |> Enum.find(&(&1["key"] == "sample"))
    assert before["health"] == after_read["health"]
    {:ok, view, _} = live(conn, "/pull-requests?project=sample")
    refute has_element?(view, "#sidebar-project-sample", "down")
    Foreman.RuntimeState.record("sample", {:error, :unreachable})
    send(view.pid, :reconcile)
    assert has_element?(view, "#sidebar-project-sample", "down")
  end
end
