defmodule ForemanWeb.InitiativesLiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    {:ok, config} =
      Foreman.Config.parse_layers([{"defaults", File.read!("priv/foreman.defaults.toml")}])

    config =
      Map.put(config, "repos", [%{"key" => "sample", "path" => "/tmp/sample", "enabled" => true}])

    Foreman.Repo.insert_all("board_config", [
      %{
        id: 1,
        config: config,
        source: "/tmp/settings",
        discovered: [],
        loaded_at: DateTime.utc_now()
      }
    ])

    rows = [
      b("e", "epic"),
      b("a", "task", [%{depends_on_id: "e", type: "parent-child"}], "closed"),
      Map.put(b("f", "bug", [%{depends_on_id: "a", type: "discovered-from"}]), :labels, [
        "follow-up"
      ]),
      b("o", "chore")
    ]

    Foreman.Beads.Projection.replace("sample", Enum.map_join(rows, "\n", &Jason.encode!/1))
    :ok
  end

  test "kind sections own whole trees and loose tickets, excluding closed and parked", %{
    conn: conn
  } do
    rows = [
      Map.put(b("e", "epic"), :kind, "feature"),
      Map.put(b("child", "task", [%{depends_on_id: "e", type: "parent-child"}]), :kind, "access"),
      Map.put(b("fix", "bug"), :kind, "break_fix"),
      b("unknown", "task"),
      Map.put(b("closed", "task", [], "closed"), :kind, "mapping"),
      b("closed_child", "task", [%{depends_on_id: "e", type: "parent-child"}], "closed")
    ]

    Foreman.Beads.Projection.replace("sample", Enum.map_join(rows, "\n", &Jason.encode!/1))
    data = Foreman.Initiatives.snapshot()
    assert Enum.map(Map.get(data, :sections, []), & &1.kind) == ~w(break_fix feature unsorted)
    assert Enum.map(data.sections, & &1.count) == [1, 2, 1]
    feature = Enum.find(data.sections, &(&1.kind == "feature"))
    assert Enum.map(hd(feature.epics).planned, & &1.id) == ["child"]
    {:ok, view, _} = live(conn, "/")

    assert has_element?(
             view,
             "#parked-panel ~ #kind-break_fix-panel ~ #kind-feature-panel ~ #kind-unsorted-panel"
           )

    refute has_element?(view, "#kind-mapping-panel")
    assert has_element?(view, "#kind-feature-count", "2")
    assert has_element?(view, "select[name='filters[kind]'] option[value=unsorted]")

    view
    |> element("#initiative-filters")
    |> render_change(%{"filters" => %{"kind" => "break_fix"}})

    assert has_element?(view, "#kind-break_fix-panel")
    refute has_element?(view, "#kind-feature-panel")
  end

  test "all kind headers follow Parked in the declared order", %{conn: conn} do
    rows =
      Enum.map(~w(break_fix mapping access feature internal), &Map.put(b(&1, "task"), :kind, &1)) ++
        [b("unknown", "task")]

    Foreman.Beads.Projection.replace("sample", Enum.map_join(rows, "\n", &Jason.encode!/1))
    {:ok, view, _} = live(conn, "/")

    assert has_element?(
             view,
             "#parked-panel + #kind-break_fix-panel + #kind-mapping-panel + #kind-access-panel + #kind-feature-panel + #kind-internal-panel + #kind-unsorted-panel"
           )
  end

  test "repo default fills missing kinds without overriding explicit epic kind", %{conn: conn} do
    Foreman.Repo.query!(
      "UPDATE board_config SET config = jsonb_set(config, '{repos,0,default_kind}', '\"internal\"')"
    )

    rows = [
      Map.put(b("e", "epic"), :kind, "feature"),
      b("child", "task", [%{depends_on_id: "e", type: "parent-child"}]),
      b("loose", "task")
    ]

    Foreman.Beads.Projection.replace("sample", Enum.map_join(rows, "\n", &Jason.encode!/1))
    data = Foreman.Initiatives.snapshot()
    assert Enum.map(data.sections, &{&1.kind, &1.count}) == [{"feature", 2}, {"internal", 1}]
    {:ok, view, _} = live(conn, "/?kind=feature")
    view |> element("#kind-feature [data-bead=e] button") |> render_click()
    assert has_element?(view, "#kind-feature [data-bead=child]")
    refute has_element?(view, "#kind-internal-panel")
  end

  test "a ticket linked to two epic roots belongs to only one kind section" do
    rows = [
      Map.put(b("root1", "epic"), :kind, "feature"),
      Map.put(b("root2", "epic"), :kind, "mapping"),
      b("shared", "task", [
        %{depends_on_id: "root1", type: "parent-child"},
        %{depends_on_id: "root2", type: "parent-child"}
      ])
    ]

    Foreman.Beads.Projection.replace("sample", Enum.map_join(rows, "\n", &Jason.encode!/1))
    data = Foreman.Initiatives.snapshot()
    assert Enum.sum(Enum.map(data.sections, & &1.count)) == 3

    assert Enum.count(
             Enum.flat_map(data.sections, & &1.epics),
             &Enum.any?(&1.planned, fn b -> b.id == "shared" end)
           ) == 1
  end

  test "unresolved discovery and children of closed epics stay visible" do
    rows = [
      b("closed", "epic", [], "closed"),
      b("child", "task", [%{depends_on_id: "closed", type: "parent-child"}]),
      b("missing", "task", [%{depends_on_id: "absent", type: "discovered-from"}])
    ]

    Foreman.Beads.Projection.replace("sample", Enum.map_join(rows, "\n", &Jason.encode!/1))
    data = Foreman.Initiatives.snapshot()

    assert Enum.flat_map(data.sections, &Enum.map(&1.never_started, fn t -> t.id end)) == [
             "child",
             "missing"
           ]
  end

  test "the global coordinator offers state, focus, resume and a separate fresh start", %{
    conn: conn
  } do
    {:ok, _, :adopt} = Foreman.Sessions.prepare_coordinator({:adopt, Ecto.UUID.generate()})
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#coordinator-state", "ended")
    assert has_element?(view, "#coordinator-focus")
    assert has_element?(view, "#coordinator-relaunch")
    assert has_element?(view, "#coordinator-fresh[data-confirm]")
  end

  test "an idle coordinator shows waiting on its row with nothing in Needs you", %{conn: conn} do
    {:ok, s, :fresh} = Foreman.Sessions.prepare_coordinator(:resume, window: "@123")
    {:waiting, facts} = Foreman.SessionHooks.facts("Stop", %{})

    {:ok, _} =
      Foreman.SessionWaiting.ask(Foreman.Sessions.coordinator_key(), %{
        "session" => s.session_id,
        "facts" => facts
      })

    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#coordinator-state", "waiting")
    refute has_element?(view, "#needs-you-count")
  end

  test "sheet preview is explicit and exposes running URL, logs and stop", %{conn: conn} do
    key = {"sample", "f"}

    Foreman.Overlay.apply_event(
      key,
      {:dispatch, %{window: "preview", workdir: System.tmp_dir!()}}
    )

    {:ok, view, _} = live(conn, "/?ticket=sample:f")
    assert has_element?(view, "#preview-start")
    assert Foreman.Previews.for_ticket(key).state == :none
    view |> element("#preview-start") |> render_click()
    assert has_element?(view, "#preview-state", "starting")
    Foreman.Previews.reconcile(Foreman.FakeDevserve)
    send(view.pid, :reconcile)
    assert has_element?(view, "#preview-open[href='http://127.0.0.1:4888']")
    assert has_element?(view, "#preview-logs", "Listening on localhost")
    view |> element("#preview-stop") |> render_click()
    assert Foreman.Previews.for_ticket(key).state == :stopping
  end

  test "ticket sections render Markdown and disabled acceptance checkboxes", %{conn: conn} do
    raw =
      b("markdown", "task")
      |> Map.merge(%{
        description: "## Reader\n\n[Spec](docs/spec.md)\n\n<script>alert(1)</script>",
        acceptance_criteria: "- [x] Complete\n- [ ] Pending",
        design: "**Design**"
      })

    Foreman.Beads.Projection.replace("sample", Jason.encode!(raw))
    {:ok, view, _} = live(conn, "/?ticket=sample:markdown")
    assert has_element?(view, "#ticket-overview .fm-markdown h2", "Reader")
    assert has_element?(view, "#ticket-overview input[type=checkbox][disabled][checked]")
    assert has_element?(view, "#ticket-overview a[href='/documents/sample?path=docs%2Fspec.md']")
    refute has_element?(view, "#ticket-overview script")
  end

  test "overview omits absent fields and empty relationship sections", %{conn: conn} do
    raw =
      b("empty", "task") |> Map.merge(%{close_reason: nil, labels: [], closed_at: nil, notes: ""})

    Foreman.Beads.Projection.replace("sample", Jason.encode!(raw))
    {:ok, view, _} = live(conn, "/?ticket=sample:empty")
    refute has_element?(view, "#ticket-overview dt", "close reason")
    refute has_element?(view, "#ticket-overview dt", "labels")
    refute has_element?(view, "#ticket-overview dt", "closed at")
    refute has_element?(view, "#ticket-overview h3", "Dependencies")
    refute has_element?(view, "#ticket-overview h3", "Linked CRs")
  end

  test "file ticket supersedes appears on the sheet even when its target is absent", %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "fm-sheet-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "tickets"))
    {_, 0} = System.cmd("git", ["init", "-q", root])
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(root, "tickets/demo-new.md"), """
    ---
    id: demo-new
    title: Replacement
    type: chore
    status: open
    priority: 2
    parent: null
    blocked_by: []
    related: []
    supersedes: [demo-old]
    discovered_from: null
    labels: []
    created: 2026-10-18
    closed: null
    close_reason: null
    ---
    """)

    {:ok, snapshot} = Foreman.TicketFiles.snapshot(root)
    {[raw], []} = Foreman.TicketFiles.decode(snapshot, [])
    Foreman.Beads.Projection.replace("sample", Jason.encode!(raw))
    {:ok, view, _} = live(conn, "/?ticket=sample:demo-new")
    assert has_element?(view, "#ticket-overview span", "supersedes · demo-old")
  end

  test "file ticket acceptance shows checked and total", %{conn: conn} do
    raw =
      b("progress", "task")
      |> Map.put(:acceptance_progress, %{"checked" => 1, "total" => 3})
      |> Map.put(:created_at, "2026-10-18T00:00:00Z")

    Foreman.Beads.Projection.replace("sample", Jason.encode!(raw))
    {:ok, view, _} = live(conn, "/?ticket=sample:progress")
    assert has_element?(view, "#ticket-acceptance-progress", "1/3")
    assert has_element?(view, "#ticket-overview time[datetime='2026-10-18T00:00:00Z']")
  end

  test "sheet tab is selected from valid, unknown and missing URL params", %{conn: conn} do
    for {query, selected} <- [
          {"", "overview"},
          {"&tab=history", "history"},
          {"&tab=sessions", "sessions"},
          {"&tab=notes", "notes"},
          {"&tab=unknown", "overview"},
          {"&tab[]=history", "overview"}
        ] do
      {:ok, view, _} = live(conn, "/?ticket=sample:f" <> query)
      assert has_element?(view, "#ticket-#{selected}-tab[aria-selected=true]")
      assert has_element?(view, "#ticket-#{selected}-panel:not([hidden])")
      assert has_element?(view, "#ticket-overview h3")

      for section <- ~w(history sessions notes) do
        refute has_element?(view, "#ticket-#{section}-section > h3")
      end

      for other <- ~w(overview history sessions notes) -- [selected] do
        assert has_element?(view, "#ticket-#{other}-panel[hidden]")
      end
    end
  end

  test "tab patches retain ticket and all filters, close clears sheet params", %{conn: conn} do
    {:ok, view, _} =
      live(
        conn,
        "/?ticket=sample:f&project=sample&type=bug&label=follow-up&status=open&stale=true&q=f"
      )

    view |> element("#ticket-history-tab") |> render_click()
    params = URI.decode_query(URI.parse(assert_patch(view)).query)

    assert params == %{
             "ticket" => "sample:f",
             "tab" => "history",
             "project" => "sample",
             "type" => "bug",
             "label" => "follow-up",
             "status" => "open",
             "stale" => "true",
             "q" => "f"
           }

    assert has_element?(view, "#ticket-history-panel:not([hidden])")
    view |> element("#ticket-close") |> render_click()
    closed = URI.decode_query(URI.parse(assert_patch(view)).query)
    assert closed == Map.drop(params, ["ticket", "tab"])
  end

  test "hidden streams update before switching tabs", %{conn: conn} do
    {:ok, view, _} = live(conn, "/?ticket=sample:f")
    Foreman.Overlay.apply_event({"sample", "f"}, {:dispatch, %{window: "tab-worker"}})

    Foreman.Overlay.apply_event(
      {"sample", "f"},
      {:report, %{body: "Fresh tab report", path: "docs/report.md"}}
    )

    send(view.pid, {:notification, :foreman_events, "sample/f"})
    assert has_element?(view, "#ticket-history-panel[hidden] #ticket-history", "dispatch")
    assert has_element?(view, "#ticket-sessions-panel[hidden] #ticket-sessions", "tab-worker")
    assert has_element?(view, "#ticket-notes-panel[hidden] #ticket-notes", "Fresh tab report")

    for {tab, content} <- [
          {"history", "dispatch"},
          {"sessions", "tab-worker"},
          {"notes", "Fresh tab report"}
        ] do
      view |> element("#ticket-#{tab}-tab") |> render_click()
      assert_patch(view)
      assert has_element?(view, "#ticket-#{tab}-panel:not([hidden])", content)
    end
  end

  test "ticket rows open a URL sheet and closing retains filters and expansion", %{conn: conn} do
    {:ok, view, _} = live(conn, "/?project=sample&type=bug")
    view |> element("[data-bead=e] button") |> render_click()
    view |> element("[data-bead=f] a") |> render_click()
    path = assert_patch(view)
    assert URI.decode_query(URI.parse(path).query)["ticket"] == "sample:f"
    assert has_element?(view, "#ticket-sheet[data-open=true]")
    assert has_element?(view, "#ticket-title", "f")
    assert has_element?(view, "#ticket-actions")
    view |> element("#ticket-close") |> render_click()
    closed = assert_patch(view)
    assert URI.decode_query(URI.parse(closed).query)["type"] == "bug"
    refute has_element?(view, "#ticket-sheet[data-open=true]")
    assert has_element?(view, "[data-bead=f]")
  end

  test "direct sheet URLs and live updates retain their underlying page", %{conn: conn} do
    {:ok, view, _} = live(conn, "/?ticket=sample:f&project=sample")
    assert has_element?(view, "#ticket-stage", "queued")
    Foreman.Overlay.apply_event({"sample", "f"}, :review)
    Foreman.Overlay.apply_event({"sample", "f"}, {:dispatch, %{window: "worker"}})
    send(view.pid, {:notification, :foreman_events, "sample/f"})
    assert has_element?(view, "#ticket-stage", "dispatched")
    assert has_element?(view, "#ticket-history [data-outcome=invalid]", "review")
    assert has_element?(view, "#ticket-sessions", "worker")
    render_patch(view, "/?project=sample")
    refute has_element?(view, "#ticket-sheet[data-open=true]")
    render_patch(view, "/?ticket=sample:f&project=sample")
    assert has_element?(view, "#ticket-sheet[data-open=true]")
  end

  test "epic route shows columns, fallout, history and opens a sheet", %{conn: conn} do
    {:ok, view, _} = live(conn, "/epics/sample/e?type=bug")
    assert has_element?(view, "#epic-title", "e")
    assert has_element?(view, "#epic-history", "backfill")
    assert has_element?(view, "[data-band=planned] [data-ticket=a]")
    assert has_element?(view, "[data-band=fallout] [data-ticket=f]")
    view |> element("[data-band=fallout] [data-ticket=f]") |> render_click()
    assert_patch(view, "/epics/sample/e?ticket=sample%3Af&type=bug")
    assert has_element?(view, "#ticket-sheet[data-open=true]")
    view |> element("#ticket-close") |> render_click()
    assert_patch(view, "/epics/sample/e?type=bug")
    Foreman.Overlay.apply_event({"sample", "f"}, {:dispatch, %{window: "worker"}})
    send(view.pid, {:notification, :foreman_events, "sample/f"})
    assert has_element?(view, "[data-band=fallout] [data-stage=dispatched]")
  end

  test "epic title navigation carries filters and missing routes stay usable", %{conn: conn} do
    {:ok, view, _} = live(conn, "/?project=sample&type=bug")
    view |> element("[data-bead=e] a") |> render_click()
    assert_redirect(view, "/epics/sample/e?project=sample&type=bug")
    {:ok, missing, _} = live(conn, "/epics/sample/missing?ticket[]=bad")
    assert has_element?(missing, "#epic-not-found")
    refute has_element?(missing, "#ticket-sheet[data-open=true]")
  end

  test "epic config and own history refresh while a sheet is open", %{conn: conn} do
    {:ok, view, _} = live(conn, "/epics/sample/e?ticket=sample:f")

    config =
      Foreman.RuntimeState.config().config
      |> Map.put("columns", [%{"title" => "Everything", "stages" => ["queued", "done"]}])

    Foreman.Repo.query!("UPDATE board_config SET config = $1", [config])
    Foreman.Overlay.apply_event({"sample", "e"}, :bead_epic_closed)
    send(view.pid, {:notification, :foreman_events, "sample/e"})
    assert has_element?(view, "#epic-columns h3", "Everything")
    assert has_element?(view, "#epic-history", "bead_epic_closed")
    assert has_element?(view, "#ticket-sheet[data-open=true]")

    rows =
      Foreman.Beads.Projection.list_raw("sample")
      |> Enum.map(fn raw ->
        if raw["id"] == "f", do: Map.put(raw, "title", "Updated fallout"), else: raw
      end)

    Foreman.Beads.Projection.replace("sample", Enum.map_join(rows, "\n", &Jason.encode!/1))
    send(view.pid, {:notification, :foreman_events, "sample"})
    assert has_element?(view, "#ticket-title", "Updated fallout")
    assert has_element?(view, "[data-ticket=f]", "Updated fallout")
  end

  test "a late close callback cannot dismiss a different selected ticket", %{conn: conn} do
    {:ok, view, _} = live(conn, "/?ticket=sample:f")
    render_patch(view, "/?ticket=sample:a")
    render_click(view, "close-ticket", %{"key" => "sample:f"})
    assert has_element?(view, "#ticket-title", "Title a")
    assert has_element?(view, "#ticket-sheet[data-open=true]")
  end

  test "history uses relative time, human payload fields and only refusal badges", %{conn: conn} do
    Foreman.Overlay.apply_event({"sample", "f"}, :review, %{actor: "reviewer"})

    Foreman.Overlay.apply_event(
      {"sample", "f"},
      {:dispatch,
       %{
         window: "worker",
         branch: "feature",
         brief_path: "docs/brief.md",
         internal_token: "hidden-detail"
       }},
      %{actor: "builder"}
    )

    Foreman.Overlay.apply_event(
      {"sample", "f"},
      {:report, %{path: "docs/report.md", body: "Verified result"}}
    )

    Foreman.Repo.query!(
      "UPDATE stage_events SET inserted_at = NOW() - INTERVAL '2 hours 5 seconds'"
    )

    {:ok, view, _} = live(conn, "/epics/sample/e?ticket=sample:f")
    assert has_element?(view, "#epic-history time[title][datetime]", "2 h ago")
    assert has_element?(view, "#ticket-history time[title][datetime]", "2 h ago")
    assert has_element?(view, "#ticket-sessions time[title][datetime]")
    assert has_element?(view, "#ticket-history [data-outcome=invalid]", "Refused")
    assert has_element?(view, "#ticket-history [data-outcome=row]", "feature")
    assert has_element?(view, "#ticket-history [data-outcome=row]", "docs/brief.md")
    assert has_element?(view, "#ticket-history [data-outcome=row]", "builder")
    assert has_element?(view, "#ticket-history dt", "Report")

    assert has_element?(
             view,
             "#ticket-history a[href='/documents/sample?path=docs%2Freport.md']",
             "docs/report.md"
           )

    assert has_element?(
             view,
             "#ticket-history a[href='/documents/sample?path=docs%2Fbrief.md']",
             "docs/brief.md"
           )

    assert has_element?(view, "#ticket-history dd", "Verified result")
    refute has_element?(view, "#ticket-history [data-outcome=row] [data-history-outcome]")
    refute has_element?(view, "#ticket-history", "hidden-detail")
    refute has_element?(view, "#ticket-history", "record: session")
    refute has_element?(view, "#ticket-history", "emit: stage")
  end

  test "fallout omits empty cells and disappears after the last fallout edge is removed", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/epics/sample/e")

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("[data-band=fallout]")
           |> Enum.count() == 1

    rows =
      Foreman.Beads.Projection.list_raw("sample")
      |> Enum.map(fn raw ->
        if raw["id"] == "f", do: Map.put(raw, "dependencies", []), else: raw
      end)

    Foreman.Beads.Projection.replace("sample", Enum.map_join(rows, "\n", &Jason.encode!/1))
    send(view.pid, {:notification, :foreman_events, "sample"})
    refute has_element?(view, "[data-band=fallout]")
  end

  test "home has derived epic progress, expandable fallout and collapsed per-project orphans", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "h1", "Initiatives")
    assert has_element?(view, "a.bb-nav-active[aria-current=page]", "Initiatives")
    assert has_element?(view, "[data-bead=e]", "building")

    assert has_element?(
             view,
             "[data-bead=e] [role=progressbar][aria-valuenow='1'][aria-valuemax='2']"
           )

    refute has_element?(view, "[data-bead=f]")
    view |> element("[data-bead=e] button") |> render_click()
    assert has_element?(view, "#kind-unsorted h3", "Fallout")
    assert has_element?(view, "[data-bead=f]", "bug")

    assert has_element?(
             view,
             "#toggle-kind-unsorted-never_started-project-sample[aria-expanded=false]"
           )

    refute has_element?(view, "#kind-unsorted [data-bead=o]")
    view |> element("#toggle-kind-unsorted-never_started-project-sample") |> render_click()
    assert has_element?(view, "#kind-unsorted [data-bead=o]")
  end

  test "filtering children retains full progress and reconciliation refreshes stages", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/")
    view |> form("#initiative-filters", filters: %{type: "bug"}) |> render_change()
    assert has_element?(view, "[data-bead=e] [role=progressbar][aria-valuemax='2']")
    view |> element("[data-bead=e] button") |> render_click()
    assert has_element?(view, "[data-bead=f]")
    refute has_element?(view, "[data-bead=a]")
    Foreman.Overlay.apply_event({"sample", "f"}, {:cr_opened, %{number: 1}})
    send(view.pid, :reconcile)
    assert has_element?(view, "[data-bead=e]", "shipping")
    assert has_element?(view, "[data-bead=f]", "pr_open")
  end

  test "drafts appear above epics and filters cover status, label, project and stale", %{
    conn: conn
  } do
    Foreman.Overlay.apply_event(
      {"sample", "draft:next"},
      {:create, %{title: "Next initiative", spec_link: "docs/next.md"}}
    )

    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#drafts [data-bead='draft:next']", "idea")
    assert has_element?(view, "#drafts a[href='/documents/sample?path=docs%2Fnext.md']")
    assert has_element?(view, "#drafts-panel ~ #kind-unsorted-panel")
    view |> form("#initiative-filters", filters: %{status: "closed"}) |> render_change()
    refute has_element?(view, "#drafts-panel")
    refute has_element?(view, "#kind-unsorted-panel")
    view |> form("#initiative-filters", filters: %{status: "", stale: "true"}) |> render_change()
    refute has_element?(view, "[data-bead=e]")
    Foreman.Overlay.apply_event({"sample", "f"}, {:dispatch, %{window: "worker"}})
    Foreman.Repo.query!("UPDATE sessions SET last_seen_at = NOW() - INTERVAL '3 hours'")
    send(view.pid, :reconcile)
    assert has_element?(view, "[data-bead=e]", "stale")

    view
    |> form("#initiative-filters", filters: %{stale: "false", label: "follow-up"})
    |> render_change()

    refute has_element?(view, "#drafts-panel")
    assert has_element?(view, "[data-bead=e]")

    view |> element("#sidebar-project-sample") |> render_click()

    assert has_element?(view, "[data-bead=e]")
  end

  test "sub-epics expand independently and contribute to parent totals", %{conn: conn} do
    rows =
      Foreman.Beads.Projection.list_raw("sample") ++
        [
          b("sub", "epic", [%{depends_on_id: "e", type: "parent-child"}]),
          b("nested", "task", [%{depends_on_id: "sub", type: "parent-child"}])
        ]

    Foreman.Beads.Projection.replace("sample", Enum.map_join(rows, "\n", &Jason.encode!/1))
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "[data-bead=e] [aria-valuemax='3']")
    refute has_element?(view, "[data-bead=sub]")
    view |> element("[data-bead=e] button") |> render_click()
    assert has_element?(view, "[data-bead=sub] [aria-valuemax='1']")
    refute has_element?(view, "[data-bead=nested]")
    view |> element("[data-bead=sub] button") |> render_click()
    assert has_element?(view, "[data-bead=nested]")
  end

  test "finished epics are in a collapsed Done group after active epics and before Unplanned", %{
    conn: conn
  } do
    rows =
      Foreman.Beads.Projection.list_raw("sample") ++
        [
          b("done.10", "epic", [], "closed"),
          b("done.2", "epic", [], "closed"),
          b("shipped", "epic"),
          b("shipped.1", "task", [%{depends_on_id: "shipped", type: "parent-child"}], "closed"),
          b("ticketed", "epic"),
          b("shipping", "epic"),
          b("shipping.1", "task", [%{depends_on_id: "shipping", type: "parent-child"}])
        ]

    Foreman.Beads.Projection.replace("sample", Enum.map_join(rows, "\n", &Jason.encode!/1))
    Foreman.Overlay.apply_event({"sample", "shipping.1"}, {:cr_opened, %{number: 1}})
    {:ok, view, _} = live(conn, "/?view=all")
    assert has_element?(view, "#toggle-done[aria-expanded=false]")
    assert has_element?(view, "#done-count", "3")

    assert has_element?(
             view,
             "#parked-panel + #kind-unsorted-panel + #done-panel"
           )

    assert ids(view, "#kind-unsorted [data-kind=epic]") == ["e", "shipping", "ticketed"]
    refute has_element?(view, "[data-bead='done.2']")
    refute has_element?(view, "[data-bead=shipped]")
    view |> element("#toggle-done") |> render_click()
    assert ids(view, "#done [data-kind=epic]") == ["done.2", "done.10", "shipped"]
    assert has_element?(view, "#done [data-bead='done.2'] .bb-epic-progress", "—")
    refute has_element?(view, "#done [data-bead='done.2'] [role=progressbar]")
    view |> element("#done [data-bead=shipped] button") |> render_click()
    assert has_element?(view, "#done [data-bead='shipped.1']")
    view |> form("#initiative-filters", filters: %{q: "done.2"}) |> render_change()
    assert has_element?(view, "#done-count", "1")
    assert ids(view, "#done [data-kind=epic]") == ["done.2"]
    view |> element("#toggle-done") |> render_click()
    refute has_element?(view, "#done [data-kind=epic]")
  end

  test "observed closure and reopening move an expanded epic between active and Done", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/?view=all")
    view |> element("[data-bead=e] button") |> render_click()
    Foreman.Overlay.apply_event({"sample", "e"}, :bead_epic_closed)
    send(view.pid, :reconcile)
    refute has_element?(view, "#kind-unsorted [data-bead=e]")
    assert has_element?(view, "#done-count", "1")
    view |> element("#toggle-done") |> render_click()
    assert has_element?(view, "#done [data-bead=e]")
    assert has_element?(view, "#done [data-bead=a]")
    Foreman.Overlay.apply_event({"sample", "e"}, :bead_epic_reopened)
    send(view.pid, :reconcile)
    assert has_element?(view, "#kind-unsorted [data-bead=e]")
    refute has_element?(view, "#kind-unsorted [data-bead=a]")
    assert has_element?(view, "#done-count", "0")
    refute has_element?(view, "#done [data-bead=e]")
  end

  test "an epic without child tickets shows a dash instead of progress", %{conn: conn} do
    rows = Foreman.Beads.Projection.list_raw("sample") ++ [b("empty", "epic")]
    Foreman.Beads.Projection.replace("sample", Enum.map_join(rows, "\n", &Jason.encode!/1))
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "[data-bead=empty] .bb-epic-progress", "—")
    refute has_element?(view, "[data-bead=empty] [role=progressbar]")
    refute has_element?(view, "[data-bead=empty] .bb-epic-progress", "0 / 0")
    refute has_element?(view, "[data-bead=empty] .bb-epic-progress", "%")
    assert has_element?(view, "[data-bead=e] [role=progressbar][aria-valuemax='2']")
  end

  test "persisted board-side links include cross-repo tickets without seeding beads edges", %{
    conn: conn
  } do
    config = Foreman.RuntimeState.config().config

    config =
      Map.update!(
        config,
        "repos",
        &(&1 ++ [%{"key" => "other", "path" => "/tmp/other", "enabled" => true}])
      )

    Foreman.Repo.query!("UPDATE board_config SET config = $1 WHERE id = 1", [config])
    Foreman.Beads.Projection.replace("other", Jason.encode!(b("external", "task")))

    Foreman.Repo.insert_all("epic_links", [
      %{repo_key: "other", bead_id: "external", epic_repo_key: "sample", epic_bead_id: "e"}
    ])

    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "[data-bead=e] [aria-valuemax='3']")
    view |> element("[data-bead=e] button") |> render_click()
    assert has_element?(view, "[data-bead=external]", "Title external")
    assert [%{"dependencies" => []}] = Foreman.Beads.Projection.list_raw("other")
  end

  test "URL filters populate controls and changes patch a shareable URL", %{conn: conn} do
    {:ok, view, _} =
      live(conn, "/?project=sample&type=bug&label=follow-up&status=open&q=Title&stale=false")

    assert has_element?(view, "#filters_type option[value=bug][selected]")
    assert has_element?(view, "#sidebar-project-sample.bb-nav-active")
    assert has_element?(view, "#filters_q[value=Title]")
    view |> form("#initiative-filters", filters: %{q: "a & b"}) |> render_change()
    path = assert_patch(view)
    assert URI.decode_query(URI.parse(path).query)["q"] == "a & b"
    assert URI.decode_query(URI.parse(path).query)["type"] == "bug"
  end

  test "returning from Settings restores this browser's filters", %{conn: conn} do
    remembered = %{
      "project" => "sample",
      "type" => "bug",
      "label" => "follow-up",
      "status" => "open",
      "q" => "Title",
      "stale" => "false"
    }

    {:ok, settings, _} = live(conn, "/settings")

    assert {:error, {:live_redirect, %{to: "/"}}} =
             settings |> element("a", "Initiatives") |> render_click()

    {:ok, view, _} = live(put_connect_params(conn, %{"initiative_filters" => remembered}), "/")
    assert has_element?(view, "#filters_type option[value=bug][selected]")

    for {key, value} <- Map.drop(remembered, ["q", "stale", "project"]) do
      assert has_element?(view, "#filters_#{key} option[value='#{value}'][selected]")
    end

    assert has_element?(view, "#initiative-filter-memory[data-filters]")
    render_patch(view, "/")
    refute has_element?(view, "#sidebar-project-sample.bb-nav-active")
    assert has_element?(view, "#filters_type option[value=''][selected]")
  end

  test "explicit URLs override remembered filters, including an explicit clear", %{conn: conn} do
    conn =
      put_connect_params(conn, %{
        "initiative_filters" => %{"project" => "sample", "type" => "bug"}
      })

    {:ok, view, _} = live(conn, "/?project=")
    refute has_element?(view, "#sidebar-project-sample.bb-nav-active")
    assert has_element?(view, "#filters_type option[value=''][selected]")
  end

  test "malformed and unknown URL values fall back to defaults", %{conn: conn} do
    {:ok, view, _} =
      live(conn, "/?project[]=sample&type=invalid&label[bad]=x&status=no&stale=yes&q[]=bad")

    for key <- ~w(type label status) do
      assert has_element?(view, "#filters_#{key} option[value=''][selected]")
    end

    assert has_element?(view, "#filters_q[value='']")
    refute has_element?(view, "#filters_stale[checked]")
    assert has_element?(view, "[data-bead=e]")
  end

  test "sidebar project patches and toggles without losing other filters or counts", %{conn: conn} do
    {:ok, view, _} = live(conn, "/?type=bug")
    assert has_element?(view, "#sidebar-project-sample", "4")
    view |> element("#sidebar-project-sample") |> render_click()
    assert URI.decode_query(URI.parse(assert_patch(view)).query)["project"] == "sample"
    assert has_element?(view, "#sidebar-project-sample.bb-nav-active[aria-current=true]")
    assert has_element?(view, "#filters_type option[value=bug][selected]")
    assert has_element?(view, "#sidebar-project-sample", "4")
    view |> element("#sidebar-project-sample") |> render_click()
    assert URI.decode_query(URI.parse(assert_patch(view)).query)["project"] == ""
    refute has_element?(view, "#sidebar-project-sample.bb-nav-active")
    assert has_element?(view, "#filters_type option[value=bug][selected]")
  end

  test "Settings sidebar navigates to an explicit project filter", %{conn: conn} do
    {:ok, view, _} = live(conn, "/settings")
    assert has_element?(view, "#sidebar-project-sample", "4")

    assert {:error, {:live_redirect, %{to: path}}} =
             view |> element("#sidebar-project-sample") |> render_click()

    assert URI.decode_query(URI.parse(path).query)["project"] == "sample"
    {:ok, initiatives, _} = live(conn, path)
    assert has_element?(initiatives, "#sidebar-project-sample.bb-nav-active")
  end

  test "initial URL filters exclude nonmatching streamed rows", %{conn: conn} do
    Foreman.Beads.Projection.replace(
      "sample",
      Enum.map_join([b("e", "epic"), b("excluded", "epic")], "\n", &Jason.encode!/1)
    )

    {:ok, filtered, _} = live(conn, "/?q=Title+excluded")
    assert has_element?(filtered, "#kind-unsorted [data-bead=excluded]")
    refute has_element?(filtered, "#kind-unsorted [data-bead=e]")
  end

  test "curated views default to Open and selection patches while retaining search and project",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#view-open[aria-pressed=true][type=button]")
    assert has_element?(view, "#initiative-filters[phx-submit=filter]")
    assert has_element?(view, "#view-in-flight")
    assert has_element?(view, "#view-stale")
    assert has_element?(view, "#view-all")
    render_patch(view, "/?view=open&project=sample&q=Title")
    assert_patch(view)
    view |> element("#view-in-flight") |> render_click()
    params = URI.decode_query(URI.parse(assert_patch(view)).query)
    assert params["view"] == "in-flight"
    assert params["project"] == "sample"
    assert params["q"] == "Title"
    refute has_element?(view, "[data-bead=e]")
    Foreman.Overlay.apply_event({"sample", "f"}, {:dispatch, %{window: "worker"}})
    send(view.pid, :reconcile)
    assert has_element?(view, "[data-bead=e]")
    view |> element("[data-bead=e] button") |> render_click()
    assert has_element?(view, "[data-bead=f]")
    refute has_element?(view, "[data-bead=a]")
    view |> element("#view-all") |> render_click()
    refute has_element?(view, "[data-bead=a]")
  end

  test "Filters starts closed, counts only advanced overrides and remembers disclosure independently",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/?view=open&type=bug&label=follow-up&q=Title&project=sample")
    assert has_element?(view, "#toggle-filters[aria-expanded=false]")
    assert has_element?(view, "#advanced-filters[hidden]")
    assert has_element?(view, "#advanced-filter-count", "2")
    refute has_element?(view, "#filters_project")
    view |> element("#toggle-filters") |> render_click()
    assert has_element?(view, "#toggle-filters[aria-expanded=true]")
    refute has_element?(view, "#advanced-filters[hidden]")
    refute has_element?(view, "#advanced-filter-count")
    assert has_element?(view, "#initiative-filter-memory[data-filters-open=true]")
    view |> element("#view-stale") |> render_click()
    assert has_element?(view, "#toggle-filters[aria-expanded=true]")

    {:ok, returned, _} =
      live(put_connect_params(conn, %{"initiative_filters_open" => "true"}), "/?view=all")

    assert has_element?(returned, "#toggle-filters[aria-expanded=true]")
    {:ok, corrupt, _} = live(put_connect_params(conn, %{"initiative_filters_open" => "bad"}), "/")
    assert has_element?(corrupt, "#toggle-filters[aria-expanded=false]")
    refute has_element?(corrupt, "#advanced-filter-count")
  end

  test "legacy URLs remain unscoped and explicit overrides beat a view", %{conn: conn} do
    rows = Foreman.Beads.Projection.list_raw("sample") ++ [b("closed", "epic", [], "closed")]
    Foreman.Beads.Projection.replace("sample", Enum.map_join(rows, "\n", &Jason.encode!/1))
    {:ok, legacy, _} = live(conn, "/?status=closed")
    refute has_element?(legacy, "#initiative-views [aria-pressed=true]")
    assert has_element?(legacy, "#done-count", "1")
    {:ok, explicit, _} = live(conn, "/?view=open&status=closed")
    assert has_element?(explicit, "#done-count", "1")
    assert has_element?(explicit, "#advanced-filter-count", "1")
    {:ok, all, _} = live(conn, "/?view=open&status=all")
    assert has_element?(all, "#done-count", "1")
    {:ok, unknown, _} = live(conn, "/?view=missing")
    assert has_element?(unknown, "#view-open[aria-pressed=true]")
    assert has_element?(unknown, "#done-count", "0")
  end

  test "reload updates curated buttons and resolves a removed selection to the new default", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/?view=in-flight")
    config = Foreman.RuntimeState.config().config
    config = Map.put(config, "views", [%{"key" => "everything", "title" => "Everything"}])
    Foreman.Repo.query!("UPDATE board_config SET config = $1 WHERE id = 1", [config])
    send(view.pid, :reconcile)
    assert has_element?(view, "#view-everything[aria-pressed=true]", "Everything")
    refute has_element?(view, "#view-in-flight")
    assert has_element?(view, "[data-bead=e]")
  end

  test "persisted pre-views configuration uses shipped presets until its next reload", %{
    conn: conn
  } do
    config = Map.delete(Foreman.RuntimeState.config().config, "views")
    Foreman.Repo.query!("UPDATE board_config SET config = $1 WHERE id = 1", [config])
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#view-open[aria-pressed=true]")
  end

  test "advanced count includes a false-valued label and disabling the stale preset", %{
    conn: conn
  } do
    rows =
      Foreman.Beads.Projection.list_raw("sample") ++
        [Map.put(b("flag", "task"), :labels, ["false"])]

    Foreman.Beads.Projection.replace("sample", Enum.map_join(rows, "\n", &Jason.encode!/1))
    {:ok, view, _} = live(conn, "/?view=stale&label=false&stale=false")
    assert has_element?(view, "#advanced-filter-count", "2")
    render_patch(view, "/?view=all&status=all&stale=false")
    refute has_element?(view, "#advanced-filter-count")
  end

  test "Stale selects stale tickets without changing rollups or counting the preset as advanced",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/?view=stale")
    refute has_element?(view, "[data-bead=e]")
    refute has_element?(view, "#advanced-filter-count")
    Foreman.Overlay.apply_event({"sample", "f"}, {:dispatch, %{window: "worker"}})
    Foreman.Repo.query!("UPDATE sessions SET last_seen_at = NOW() - INTERVAL '3 hours'")
    send(view.pid, :reconcile)
    assert has_element?(view, "[data-bead=e] [aria-valuemax='2']")
    view |> element("[data-bead=e] button") |> render_click()
    assert has_element?(view, "[data-bead=f]")
    refute has_element?(view, "[data-bead=a]")
    refute has_element?(view, "#advanced-filter-count")
  end

  test "Unplanned sorts newest first with stable ties and missing dates last", %{conn: conn} do
    rows = [
      b("a-missing", "task"),
      Map.put(b("b-old", "task"), :created, "2026-01-01"),
      Map.put(b("c-new", "task"), :created_at, "2026-10-20T10:00:00Z"),
      Map.put(b("d-tie", "task"), :created_at, "2026-10-20T12:00:00+02:00"),
      b("e-missing", "task"),
      Map.put(b("f-earlier", "task"), :created_at, "2026-10-20T09:00:00Z")
    ]

    assert {:ok, _} =
             Foreman.Beads.Projection.replace(
               "sample",
               Enum.map_join(rows, "\n", &Jason.encode!/1)
             )

    {:ok, view, _} = live(conn, "/")
    view |> element("#toggle-kind-unsorted-never_started-project-sample") |> render_click()

    assert ids(view, "#kind-unsorted [data-bead]") ==
             ~w(c-new d-tie f-earlier b-old a-missing e-missing)

    send(view.pid, :reconcile)

    assert ids(view, "#kind-unsorted [data-bead]") ==
             ~w(c-new d-tie f-earlier b-old a-missing e-missing)
  end

  test "ticket ages and full-date tooltips appear on Unplanned and epic children", %{conn: conn} do
    today = Date.utc_today()

    rows = [
      b("e", "epic"),
      Map.put(
        b("child", "task", [%{depends_on_id: "e", type: "parent-child"}]),
        :created_at,
        Date.to_iso8601(Date.add(today, -35)) <> "T12:00:00Z"
      ),
      Map.put(b("orphan", "task"), :created, Date.to_iso8601(today)),
      b("missing", "task")
    ]

    assert {:ok, _} =
             Foreman.Beads.Projection.replace(
               "sample",
               Enum.map_join(rows, "\n", &Jason.encode!/1)
             )

    {:ok, view, _} = live(conn, "/")
    view |> element("#kind-unsorted [data-bead=e] button") |> render_click()
    view |> element("#toggle-kind-unsorted-never_started-project-sample") |> render_click()

    child_date = Calendar.strftime(Date.add(today, -35), "%B %-d, %Y")
    today_date = Calendar.strftime(today, "%B %-d, %Y")

    assert has_element?(
             view,
             "#kind-unsorted [data-bead=child] time[title='Created #{child_date}']",
             "5w"
           )

    assert has_element?(
             view,
             "#kind-unsorted [data-bead=orphan] time[title='Created #{today_date}']",
             "today"
           )

    refute has_element?(view, "#kind-unsorted [data-bead=missing] time")
  end

  test "parentless buckets separate untouched work from active work and exclude closed", %{
    conn: conn
  } do
    rows =
      [
        b("untouched", "task"),
        b("claimed", "task", [], "in_progress"),
        b("closed", "task", [], "closed")
      ] ++
        Enum.map(~w(dispatched building reported in_review committed), fn stage ->
          Map.put(b(stage, "task"), :created_at, "2026-10-20T10:00:00Z")
        end)

    Foreman.Beads.Projection.replace("sample", Enum.map_join(rows, "\n", &Jason.encode!/1))

    for stage <- ~w(dispatched building reported in_review committed) do
      Foreman.Overlay.apply_event({"sample", stage}, {:dispatch, %{window: stage}})
      Foreman.Repo.query!("UPDATE tickets SET stage = $1 WHERE bead_id = $2", [stage, stage])
    end

    Foreman.Overlay.apply_event({"sample", "closed"}, {:dispatch, %{window: "closed"}})

    data = Foreman.Initiatives.snapshot()
    assert Enum.map(data.orphans, & &1.id) == ["untouched"]

    {:ok, view, _} = live(conn, "/?view=all")
    assert has_element?(view, "#kind-unsorted-count", "7")
    view |> element("#toggle-kind-unsorted-never_started-project-sample") |> render_click()
    view |> element("#toggle-kind-unsorted-in_flight-project-sample") |> render_click()

    assert ids(view, "#kind-unsorted [data-bead]") ==
             ~w(building committed dispatched in_review reported claimed untouched)

    assert has_element?(view, "#kind-unsorted [data-bead=committed] time[title][datetime]")
    refute has_element?(view, "[data-bead=closed]")
  end

  test "In flight includes standalone review, committed and tracker-claimed work", %{conn: conn} do
    rows =
      [b("claimed", "task", [], "in_progress"), b("untouched", "task")] ++
        Enum.map(~w(dispatched building reported in_review committed), &b(&1, "task"))

    Foreman.Beads.Projection.replace("sample", Enum.map_join(rows, "\n", &Jason.encode!/1))

    for stage <- ~w(dispatched building reported in_review committed) do
      Foreman.Overlay.apply_event({"sample", stage}, {:dispatch, %{window: stage}})
      Foreman.Repo.query!("UPDATE tickets SET stage = $1 WHERE bead_id = $2", [stage, stage])
    end

    {:ok, view, _} = live(conn, "/?view=in-flight")
    assert has_element?(view, "#kind-unsorted-count", "6")
    refute has_element?(view, "#kind-unsorted-never_started")
    view |> element("#toggle-kind-unsorted-in_flight-project-sample") |> render_click()

    assert ids(view, "#kind-unsorted [data-bead]") ==
             ~w(building claimed committed dispatched in_review reported)

    view |> form("#initiative-filters", filters: %{q: "committed"}) |> render_change()
    assert ids(view, "#kind-unsorted [data-bead]") == ["committed"]
    assert has_element?(view, "#kind-unsorted-count", "1")
  end

  test "reconciliation moves dispatched and closed tickets out of their former buckets", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/?view=all")
    view |> element("#toggle-kind-unsorted-never_started-project-sample") |> render_click()
    assert has_element?(view, "#kind-unsorted [data-bead=o]")

    Foreman.Overlay.apply_event({"sample", "o"}, {:dispatch, %{window: "worker"}})
    send(view.pid, :reconcile)
    refute has_element?(view, "#kind-unsorted-never_started")
    view |> element("#toggle-kind-unsorted-in_flight-project-sample") |> render_click()
    assert has_element?(view, "#kind-unsorted [data-bead=o]")

    Foreman.Beads.Projection.replace("sample", Jason.encode!(b("o", "chore", [], "closed")))
    send(view.pid, :reconcile)
    refute has_element?(view, "#kind-unsorted [data-bead=o]")
    refute has_element?(view, "#kind-unsorted-panel")
  end

  test "parked collects epic and parentless work without stale or duplicate buckets", %{
    conn: conn
  } do
    rows = [
      b("e", "epic"),
      Map.merge(
        b("p", "task", [%{depends_on_id: "e", type: "parent-child"}], "parked"),
        %{
          parked: Date.to_iso8601(Date.add(Date.utc_today(), -3)),
          parked_reason: "Vendor approval"
        }
      ),
      Map.merge(b("o", "task", [], "parked"), %{
        parked: Date.to_iso8601(Date.add(Date.utc_today(), -1)),
        parked_reason: "IT access"
      })
    ]

    Foreman.Beads.Projection.replace("sample", Enum.map_join(rows, "\n", &Jason.encode!/1))

    Foreman.Repo.insert_all(
      "tickets",
      [
        %{
          repo_key: "sample",
          bead_id: "o",
          stage: "building",
          stage_changed_at: DateTime.utc_now()
        }
      ],
      on_conflict: {:replace, [:stage]},
      conflict_target: [:repo_key, :bead_id]
    )

    snapshot = Foreman.Initiatives.snapshot()
    assert Enum.map(snapshot.parked, & &1.id) == ["p", "o"]
    assert snapshot.orphans == []
    assert snapshot.standalone == []
    refute Enum.any?(snapshot.parked, & &1.stale)
    assert Foreman.Initiatives.snapshot(%{"stale" => "true"}).parked == []
    assert length(Foreman.Initiatives.snapshot(%{"status" => "parked"}).parked) == 2

    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#parked-panel + #kind-unsorted-panel")
    assert has_element?(view, "#parked-count", "2")
    assert has_element?(view, "option[value=parked]", "Parked")
    view |> element("#toggle-parked") |> render_click()
    view |> element("#toggle-parked-project-sample") |> render_click()
    assert ids(view, "#parked [data-bead]") == ["p", "o"]
    assert has_element?(view, "#parked [data-bead=p]", "Vendor approval")
    assert has_element?(view, "#parked [data-bead=p]", "e · Title e")
    assert has_element?(view, "#parked [data-bead=p] time[title][datetime]", "3d")
    view |> element("#kind-unsorted [data-bead=e] button[phx-click=toggle]") |> render_click()
    assert has_element?(view, "#kind-unsorted [data-bead=p]", "Parked")
    view |> element("#parked [data-bead=p] a") |> render_click()
    assert has_element?(view, "#ticket-parked-reason", "Vendor approval")
    assert has_element?(view, "#ticket-unpark", "foreman update p --status in_progress")
  end

  defp ids(view, selector),
    do:
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("data-bead")

  defp b(id, type, edges \\ [], status \\ "open"),
    do: %{id: id, title: "Title #{id}", issue_type: type, status: status, dependencies: edges}
end
