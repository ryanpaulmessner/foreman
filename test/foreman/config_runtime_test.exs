defmodule Foreman.ConfigRuntimeTest do
  use Foreman.DataCase, async: false
  alias Foreman.Config.ReloadJob

  setup do
    root =
      Path.join(System.tmp_dir!(), "foreman-config-runtime-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    previous = Application.get_env(:foreman, :config_directory)
    Application.put_env(:foreman, :config_directory, root)
    Application.put_env(:foreman, :discovery_root, root)

    on_exit(fn ->
      Application.put_env(:foreman, :config_directory, previous)
      Application.delete_env(:foreman, :discovery_root)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "filesystem reads do not hold a database transaction", %{root: root} do
    Mimic.stub(File, :read, fn path ->
      refute Repo.in_transaction?(), "filesystem read inside reload transaction: #{path}"
      Mimic.call_original(File, :read, [path])
    end)

    Mimic.stub(File, :lstat, fn path ->
      refute Repo.in_transaction?(), "filesystem stat inside reload transaction: #{path}"
      Mimic.call_original(File, :lstat, [path])
    end)

    File.write!(Path.join(root, "foreman.toml"), "[board]\nswimlanes = \"none\"\n")
    assert :ok = ReloadJob.perform(%Oban.Job{})
    assert Foreman.RuntimeState.config().config["board"]["swimlanes"] == "none"
  end

  test "unchanged inputs skip the install transaction and leave the snapshot untouched", %{
    root: root
  } do
    File.write!(Path.join(root, "foreman.toml"), "[board]\nswimlanes = \"none\"\n")
    {:ok, config} = Foreman.Config.load(root)

    Repo.insert_all("board_config", [
      %{
        id: 1,
        config: config,
        source: root,
        discovered: [],
        stores: %{},
        loaded_at: DateTime.utc_now()
      }
    ])

    installed = Foreman.RuntimeState.config()
    parent = self()
    handler = "reload-noop-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:foreman, :repo, :query],
      fn _, _, meta, _ ->
        send(parent, {:query, meta.query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert :ok = ReloadJob.perform(%Oban.Job{})
    assert_receive {:query, "SELECT" <> _}
    refute_receive {:query, _}
    Mimic.stub(File, :read!, fn path -> flunk("unchanged reload read defaults: #{path}") end)
    assert :ok = ReloadJob.perform(%Oban.Job{})
    assert_receive {:query, "SELECT" <> _}
    refute_receive {:query, _}
    assert Foreman.RuntimeState.config() == installed
  end

  test "a concurrent install is not overwritten by an older prepared snapshot", %{root: root} do
    path = Path.join(root, "foreman.toml")
    File.write!(path, "[board]\nswimlanes = \"none\"\n")
    assert :ok = ReloadJob.perform(%Oban.Job{})
    installed = Foreman.RuntimeState.config()
    newer = put_in(installed.config, ["board", "swimlanes"], "project")
    File.write!(path, "[board]\nswimlanes = \"epic\"\n")

    Mimic.stub(File, :read, fn file -> Mimic.call_original(File, :read, [file]) end)

    Mimic.expect(File, :read, fn ^path ->
      Repo.update_all("board_config", set: [config: newer])
      Mimic.call_original(File, :read, [path])
    end)

    assert {:snooze, 1} = ReloadJob.perform(%Oban.Job{})
    assert Foreman.RuntimeState.config().config == newer
    assert :ok = ReloadJob.perform(%Oban.Job{})
    assert Foreman.RuntimeState.config().config["board"]["swimlanes"] == "epic"
  end

  test "a busy advisory lock snoozes instead of holding a pooled connection" do
    parent = self()
    supervisor = start_supervised!({Task.Supervisor, []})

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock(83467219)")
            send(parent, :lock_held)

            receive do
              :release -> :ok
            end
          end)
        end)
      end)

    assert_receive :lock_held
    assert {:snooze, 1} = ReloadJob.perform(%Oban.Job{})
    assert Foreman.RuntimeState.config() == nil
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder)
    assert :ok = ReloadJob.perform(%Oban.Job{})
    assert Foreman.RuntimeState.config().error == nil
  end

  test "same-size edits in the same timestamp tick still install", %{root: root} do
    path = Path.join(root, "foreman.toml")
    File.write!(path, "[board]\nswimlanes = \"none\"\n")
    timestamp = File.stat!(path).mtime
    assert :ok = ReloadJob.perform(%Oban.Job{})
    File.write!(path, "[board]\nswimlanes = \"epic\"\n")
    File.touch!(path, timestamp)
    assert :ok = ReloadJob.perform(%Oban.Job{})
    assert Foreman.RuntimeState.config().config["board"]["swimlanes"] == "epic"
  end

  test "reconcile installs a changed config without a filesystem hint", %{root: root} do
    path = Path.join(root, "foreman.toml")
    File.write!(path, "[board]\nswimlanes = \"none\"\n")
    assert :ok = ReloadJob.perform(%Oban.Job{})
    watcher = start_supervised!({Foreman.Config.Watcher, []})
    File.write!(path, "[board]\nswimlanes = \"epic\"\n")
    send(watcher, :reconcile)
    _ = :sys.get_state(watcher)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :external_reads)
    assert Foreman.RuntimeState.config().config["board"]["swimlanes"] == "epic"
  end

  test "discovery additions and removals invalidate the installed fingerprint", %{root: root} do
    assert :ok = ReloadJob.perform(%Oban.Job{})
    repo = Path.join(root, "new-repo")
    File.mkdir_p!(Path.join(repo, ".beads"))
    assert :ok = ReloadJob.perform(%Oban.Job{})
    assert Foreman.RuntimeState.config().discovered == [repo]
    File.rm_rf!(repo)
    assert :ok = ReloadJob.perform(%Oban.Job{})
    assert Foreman.RuntimeState.config().discovered == []
  end

  test "store admission changes invalidate the fingerprint without a TOML edit", %{root: root} do
    repo = Path.join(root, "work")
    File.mkdir_p!(repo)
    assert {_, 0} = System.cmd("git", ["init", "--quiet", repo])

    File.write!(
      Path.join(root, "foreman.toml"),
      "[[repos]]\nkey = \"work\"\npath = \"#{repo}\"\ntickets = \"files\"\n"
    )

    assert :ok = ReloadJob.perform(%Oban.Job{})
    assert Foreman.RuntimeState.config().stores["work"]["identity"] == "files:" <> repo

    File.rename!(Path.join(repo, ".git"), Path.join(repo, "saved-git"))
    assert :ok = ReloadJob.perform(%Oban.Job{})
    assert Foreman.RuntimeState.config().stores["work"]["identity"] == "unreachable:work"

    File.rename!(Path.join(repo, "saved-git"), Path.join(repo, ".git"))
    assert :ok = ReloadJob.perform(%Oban.Job{})
    assert Foreman.RuntimeState.config().stores["work"]["identity"] == "files:" <> repo
  end

  test "lost directory watchers stop through their declared lifecycle" do
    assert {:stopped, [stop: :restart]} = Foreman.Config.WatchMachine.step(:watching, :lost, %{})
    assert {:stopped, []} = Foreman.Config.WatchMachine.step(:stopped, :changed, %{})
  end

  test "watcher moves from an existing parent to the newly created config directory", %{
    root: root
  } do
    target = Path.join(root, "new-config")
    Application.put_env(:foreman, :config_directory, target)
    watcher = start_supervised!({Foreman.Config.Watcher, []})
    assert :sys.get_state(watcher).directory == root
    File.mkdir_p!(target)
    send(watcher, :reconcile)
    assert :sys.get_state(watcher).directory == target
    assert Repo.exists?(from j in Oban.Job, where: j.worker == "Foreman.Config.ReloadJob")
  end

  test "discovery includes nested repositories without following symlink aliases", %{root: root} do
    parent = Path.join(root, "parent")
    nested = Path.join(parent, "nested")
    File.mkdir_p!(Path.join(parent, ".beads"))
    File.mkdir_p!(Path.join(nested, ".beads"))
    File.ln_s!(parent, Path.join(root, "alias"))
    assert :ok = ReloadJob.perform(%Oban.Job{})
    assert Foreman.RuntimeState.config().discovered == [parent, nested]
  end

  test "discovery skips generated trees and stops at depth eight", %{root: root} do
    for skipped <- ~w(node_modules _build deps .git .cache vendor .venv dist coverage) do
      File.mkdir_p!(Path.join([root, skipped, "hidden", ".beads"]))
    end

    deepest = Path.join([root | List.duplicate("nested", 8)])
    File.mkdir_p!(Path.join(deepest, ".beads"))
    File.mkdir_p!(Path.join([deepest, "too-deep", ".beads"]))
    assert :ok = ReloadJob.perform(%Oban.Job{})
    assert Foreman.RuntimeState.config().discovered == [deepest]
  end

  test "a bad views edit retains the installed curated views", %{root: root} do
    path = Path.join(root, "foreman.toml")

    File.write!(
      path,
      "[[views]]\nkey = \"review\"\ntitle = \"Review\"\nstages = [\"in_review\"]\n"
    )

    assert :ok = ReloadJob.perform(%Oban.Job{})
    accepted = Foreman.RuntimeState.config()

    assert accepted.config["views"] == [
             %{"key" => "review", "title" => "Review", "stages" => ["in_review"]}
           ]

    File.write!(
      path,
      "[[views]]\nkey = \"review\"\ntitle = \"Review\"\nstatuses = [\"invented\"]\n"
    )

    assert :ok = ReloadJob.perform(%Oban.Job{})
    rejected = Foreman.RuntimeState.config()
    assert rejected.config == accepted.config
    assert rejected.loaded_at == accepted.loaded_at
    assert rejected.error =~ "foreman.toml: config.views[0].statuses[0]"
  end

  test "persists accepted config for web and retains it after a rejected edit", %{root: root} do
    File.write!(Path.join(root, "foreman.toml"), "[board]\nswimlanes = \"none\"\n")
    assert :ok = ReloadJob.perform(%Oban.Job{})

    assert %{config: %{"board" => %{"swimlanes" => "none"}}, error: nil} =
             Foreman.RuntimeState.config()

    File.write!(
      Path.join(root, "foreman.toml"),
      "[[columns]]\ntitle = \"No\"\nstages = [\"speccing\"]\n"
    )

    assert :ok = ReloadJob.perform(%Oban.Job{})

    assert %{config: %{"board" => %{"swimlanes" => "none"}}, error: error} =
             Foreman.RuntimeState.config()

    assert error =~ "speccing"
  end

  test "human merge on a forge-none repo is rejected and the installed config stays", %{
    root: root
  } do
    repo = Path.join(root, "work")
    File.mkdir_p!(repo)
    base = "[[repos]]\nkey = \"work\"\npath = \"#{repo}\"\ntickets = \"files\"\n"
    File.write!(Path.join(root, "foreman.toml"), base <> "github = \"o/r\"\nforge = \"github\"\n")
    assert :ok = ReloadJob.perform(%Oban.Job{})
    accepted = Foreman.RuntimeState.config()
    assert accepted.error == nil
    File.write!(Path.join(root, "foreman.toml"), base <> "merge_policy = \"human\"\n")
    assert :ok = ReloadJob.perform(%Oban.Job{})
    rejected = Foreman.RuntimeState.config()
    assert rejected.config == accepted.config
    assert rejected.error =~ "merge_policy \"human\" requires forge = \"github\""
    refute Foreman.MergePolicy.human_key?("work")
  end
end
