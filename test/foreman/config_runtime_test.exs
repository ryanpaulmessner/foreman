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
