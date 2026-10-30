defmodule Foreman.TicketFiles.ReaderTest do
  use Foreman.DataCase, async: false
  alias Foreman.TicketFiles.Reader
  alias Foreman.Beads.Projection

  setup do
    root = Path.join(System.tmp_dir!(), "fm-watch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "tickets"))
    System.cmd("git", ["init", "-q", root])
    on_exit(fn -> File.rm_rf!(root) end)
    repo = %{"key" => "files", "path" => root, "enabled" => true, "tickets" => "files"}

    Repo.insert_all("board_config", [
      %{
        id: 1,
        config: %{"repos" => [repo]},
        stores: %{},
        discovered: [],
        source: root,
        loaded_at: DateTime.utc_now()
      }
    ])

    %{repo: repo, root: root, path: Path.join(root, "tickets/demo-abc.md")}
  end

  def text(title) do
    "---\nid: demo-abc\ntitle: #{title}\ntype: task\nstatus: open\npriority: 2\nparent: null\nblocked_by: []\nrelated: []\ndiscovered_from: null\nlabels: []\ncreated: 2026-10-18\nclosed: null\nclose_reason: null\n---\n\n## Acceptance\n- [x] Ready\n- [ ] Later\n"
  end

  test "files preserve existing overlay identity and last good content", %{
    repo: repo,
    root: root,
    path: path
  } do
    old = %{"id" => "demo-abc", "title" => "Beads", "status" => "open", "issue_type" => "task"}
    assert {:ok, :changed} = Projection.replace("files", Jason.encode!(old))
    Foreman.Overlay.apply_event({"files", "demo-abc"}, {:dispatch, %{window: "reader-build"}})

    Foreman.Requests.ask({"files", "demo-abc"}, "decision", %{
      "facts" => %{"question" => "Keep identity?"}
    })

    Repo.insert_all("overlay_cr_links", [%{repo_key: "files", bead_id: "demo-abc", number: 42}])

    facts =
      for table <- ~w(sessions stage_events approval_requests overlay_cr_links),
          into: %{},
          do: {table, Repo.query!("SELECT * FROM " <> table <> " ORDER BY id").rows}

    Repo.update_all(from(t in "tickets", where: t.repo_key == "files"), set: [stage: "building"])
    before = Repo.one(from(t in "tickets", where: t.repo_key == "files", select: t.id))
    File.write!(path, text("Files"))
    assert {:ok, {:ok, :changed}} = Reader.publish(repo, Foreman.TicketFiles.snapshot(root))
    assert [%{"title" => "Files"}] = Projection.list_raw("files")

    for {table, rows} <- facts,
        do: assert(Repo.query!("SELECT * FROM " <> table <> " ORDER BY id").rows == rows)

    assert %{id: ^before, stage: "building", orphaned_at: nil} =
             Repo.one(
               from(t in "tickets",
                 where: t.repo_key == "files",
                 select: %{id: t.id, stage: t.stage, orphaned_at: t.orphaned_at}
               )
             )

    File.write!(path, "broken")
    assert {:ok, {:warning, [error]}} = Reader.publish(repo, Foreman.TicketFiles.snapshot(root))
    assert error =~ "demo-abc.md"
    assert [%{"title" => "Files"}] = Projection.list_raw("files")

    assert [
             %{
               "health" => %{
                 state: "warning",
                 reason: ^error,
                 file_error_count: 1,
                 succeeded_at: succeeded_at
               }
             }
           ] = Foreman.RuntimeState.repos()

    refute is_nil(succeeded_at)
  end

  test "current file type reclassifies a ticket so a draft can link it", %{
    repo: repo,
    root: root,
    path: path
  } do
    alias Foreman.{Agent, Overlay}
    File.write!(path, text("Plan"))
    assert {:ok, {:ok, :changed}} = Reader.publish(repo, Foreman.TicketFiles.snapshot(root))
    assert %{machine: Foreman.Stage} = Overlay.get({"files", "demo-abc"})
    physical_key = {"files", "demo-abc"}
    Overlay.apply_event(physical_key, {:dispatch, %{window: "reclassification-build"}})

    {:ok, decision} =
      Foreman.Requests.ask(physical_key, "decision", %{"facts" => %{"question" => "Keep?"}})

    history = Overlay.history(physical_key)
    sessions = Repo.query!("SELECT * FROM sessions WHERE repo_key = 'files' ORDER BY id").rows
    key = {"files", "draft:plan"}
    Overlay.apply_event(key, {:create, %{title: "Plan"}})
    Overlay.apply_event(key, :start_spec)
    Overlay.apply_event(key, :approve_spec)
    params = %{"event" => "ticket", "payload" => %{"beads_epic_id" => "demo-abc"}}

    assert {422, %{error: "file ticket must have type epic"}} =
             Agent.event("files", "draft:plan", params)

    File.write!(path, String.replace(text("Plan"), "type: task", "type: epic"))
    assert {:ok, {:ok, :changed}} = Reader.publish(repo, Foreman.TicketFiles.snapshot(root))
    assert %{machine: Foreman.Epic, stage: :ticketed} = Overlay.get({"files", "demo-abc"})
    assert Foreman.Requests.get(decision.id).state == "pending"
    assert Enum.all?(history, &(&1 in Overlay.history(physical_key)))

    assert Repo.query!("SELECT * FROM sessions WHERE repo_key = 'files' ORDER BY id").rows ==
             sessions

    assert {200, _} = Agent.event("files", "draft:plan", params)
    assert %{beads_epic_id: "demo-abc"} = Overlay.get(key)
  end

  test "changing a linked epic to a task keeps the draft and its decision", %{
    repo: repo,
    root: root,
    path: path
  } do
    alias Foreman.{Overlay, Requests}
    File.write!(path, String.replace(text("Plan"), "type: task", "type: epic"))
    Reader.publish(repo, Foreman.TicketFiles.snapshot(root))
    key = {"files", "draft:plan"}
    Overlay.apply_event(key, {:create, %{title: "Plan"}})
    Overlay.apply_event(key, :start_spec)
    Overlay.apply_event(key, {:approve_spec, %{spec_link: "docs/spec.md"}})
    Overlay.apply_event(key, {:ticket, %{beads_epic_id: "demo-abc"}})
    {:ok, request} = Requests.ask(key, "decision", %{"facts" => %{"question" => "Keep?"}})
    File.write!(path, text("Task"))
    assert {:ok, {:ok, :changed}} = Reader.publish(repo, Foreman.TicketFiles.snapshot(root))
    assert %{machine: Foreman.Stage, stage: :queued} = Overlay.get({"files", "demo-abc"})

    assert %{
             machine: Foreman.Epic,
             stage: :spec_approved,
             beads_epic_id: nil,
             spec_link: "docs/spec.md"
           } = Overlay.get(key)

    assert Requests.get(request.id).state == "pending"
  end

  test "a new CLI ticket can receive an ask before the reader runs", %{root: root} do
    config = Path.join(root, "config")
    File.mkdir_p!(config)

    File.write!(
      Path.join(config, "foreman.toml"),
      "[[repos]]\nkey = \"files\"\npath = #{Jason.encode!(root)}\nprefix = \"demo\"\n"
    )

    previous = System.get_env("FOREMAN_CONFIG_DIR")
    System.put_env("FOREMAN_CONFIG_DIR", config)

    on_exit(fn ->
      if previous,
        do: System.put_env("FOREMAN_CONFIG_DIR", previous),
        else: System.delete_env("FOREMAN_CONFIG_DIR")
    end)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert Foreman.CLI.run(["new", "Immediate", "--json"], cwd: root) == 0
      end)

    id = Jason.decode!(output)["id"]
    assert [] == Projection.list_raw("files")

    assert {200, request} =
             Foreman.AgentCommands.execute(%{
               "action" => "ask",
               "repo" => "files",
               "id" => id,
               "request_kind" => "decision",
               "facts" => %{"question" => "Proceed?"}
             })

    assert Foreman.Requests.get(request.id).state == "pending"
    assert [%{"id" => ^id}] = Projection.list_raw("files")
  end

  test "runtime teardown owns its reader supervisor and inotify processes", %{path: path} do
    File.write!(path, text("Owned"))
    runtime = start_supervised!(Foreman.Runtime)
    state = :sys.get_state(runtime)
    {_, reader} = state.readers["files"]
    watcher = :sys.get_state(reader).watcher
    supervisor = Process.whereis(Foreman.TicketFiles.Supervisor)
    refs = Enum.map([reader, watcher, supervisor], &Process.monitor/1)
    stop_supervised!(Foreman.Runtime)
    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _}, 2000)
    assert is_nil(Process.whereis(Foreman.TicketFiles.Supervisor))
  end

  test "rescan retires a watcher after the directory inode is replaced", %{repo: repo, root: root} do
    pid = start_supervised!({Reader, repo: repo, observer: self()})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    assert_receive {:ticket_files, {:ok, {:ok, _}}}, 2000
    ref = Process.monitor(pid)
    File.rename!(Path.join(root, "tickets"), Path.join(root, "old-tickets"))
    File.mkdir!(Path.join(root, "tickets"))
    Reader.rescan(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 2000
  end

  test "a stale sample cannot overwrite a newer edit", %{repo: repo, root: root, path: path} do
    File.write!(path, text("Old"))
    snapshot = Foreman.TicketFiles.snapshot(root)
    File.write!(path, text("New"))
    assert {:ok, {:defer, :changed}} = Reader.publish(repo, snapshot)
    assert [] == Projection.list_raw("files")
  end

  test "a retired files reader cannot overwrite a switched source", %{
    repo: repo,
    root: root,
    path: path
  } do
    File.write!(path, text("Files"))
    switched = Map.put(repo, "tickets", "beads")
    Repo.update_all("board_config", set: [config: %{"repos" => [switched]}])

    assert {:ok, {:error, :config_changed}} =
             Reader.publish(repo, Foreman.TicketFiles.snapshot(root))

    assert [] == Projection.list_raw("files")
  end

  test "periodic reconciliation recovers when directory hints are missed", %{
    repo: repo,
    path: path
  } do
    pid = start_supervised!({Reader, repo: repo, observer: self()})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    assert_receive {:ticket_files, {:ok, {:ok, _}}}, 2000
    watcher = :sys.get_state(pid).watcher
    :sys.suspend(watcher)

    try do
      File.write!(path, text("Rescanned"))
      send(pid, :periodic)
      assert_receive {:ticket_files, {:ok, {:ok, :changed}}}, 2000
      assert [%{"title" => "Rescanned"}] = Projection.list_raw("files")
    after
      :sys.resume(watcher)
    end
  end

  test "publication lock release is retried even without another directory event", %{
    repo: repo,
    root: root,
    path: path
  } do
    lock = Path.join(root, ".git/.foreman-write-lock")
    File.mkdir!(lock)
    File.write!(path, text("Published"))
    pid = start_supervised!({Reader, repo: repo, observer: self()})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    assert_receive {:ticket_files, {:ok, {:defer, :writing}}}, 2000
    File.rmdir!(lock)
    assert_receive {:ticket_files, {:ok, {:ok, :changed}}}, 2000
    assert [%{"title" => "Published"}] = Projection.list_raw("files")
  end

  test "real inotify notices hand edits and rename saves within two seconds", %{
    repo: repo,
    path: path
  } do
    pid = start_supervised!({Reader, repo: repo, observer: self()})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    assert_receive {:ticket_files, {:ok, {:ok, _}}}, 2000
    File.write!(path, text("Created"))
    assert_receive {:ticket_files, {:ok, {:ok, :changed}}}, 2000
    assert [%{"title" => "Created"}] = Projection.list_raw("files")
    File.write!(path, text("Edited"))
    assert_receive {:ticket_files, {:ok, {:ok, :changed}}}, 2000
    assert [%{"title" => "Edited"}] = Projection.list_raw("files")
    File.write!(path <> ".tmp", text("Renamed"))
    File.rename!(path <> ".tmp", path)
    assert_receive {:ticket_files, {:ok, {:ok, :changed}}}, 2000
    assert [%{"title" => "Renamed"}] = Projection.list_raw("files")
    File.rm!(path)
    Reader.rescan(pid)
    assert_receive {:ticket_files, {:ok, {:ok, :changed}}}, 2000
    assert [] == Projection.list_raw("files")
  end
end
