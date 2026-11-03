defmodule Foreman.RoleTest do
  use ExUnit.Case, async: false

  setup do
    env = System.get_env() |> Map.take(["PREVIEW", "FOREMAN_PREVIEW_READERS"])
    runtime = Application.fetch_env!(:foreman, :runtime_enabled)
    System.delete_env("PREVIEW")
    System.delete_env("FOREMAN_PREVIEW_READERS")
    Application.put_env(:foreman, :runtime_enabled, true)

    on_exit(fn ->
      System.delete_env("PREVIEW")
      System.delete_env("FOREMAN_PREVIEW_READERS")
      System.put_env(env)
      Application.put_env(:foreman, :runtime_enabled, runtime)
    end)
  end

  test "preview serves cached data without worker children or copied jobs" do
    System.put_env("PREVIEW", "1")

    for role <- ["all", "worker", "web"] do
      children = Foreman.Role.children(role, queues: [external_reads: 4])
      {Oban, opts} = List.keyfind(children, Oban, 0)
      assert opts[:queues] == false
      assert opts[:plugins] == false
      assert opts[:peer] == false
      assert opts[:notifier] == Oban.Notifiers.Postgres
      assert children -- [{Oban, opts}, ForemanWeb.Endpoint] == []
      assert ForemanWeb.Endpoint in children == (role != "worker")
    end
  end

  test "reader opt-in restores workers without lifting the preview write guard" do
    opts = [queues: [external_reads: 4, external_writes: 1, previews: 1]]
    normal = Foreman.Role.children("all", opts)
    assert Foreman.Runtime in normal
    assert Foreman.Config.Watcher in normal
    assert Foreman.SessionMonitor in normal
    assert Foreman.CloseOutNagMonitor in normal

    System.put_env("PREVIEW", "1")
    System.put_env("FOREMAN_PREVIEW_READERS", "1")
    assert Foreman.Role.children("all", opts) == normal
    refute Foreman.Runtime in Foreman.Role.children("web", opts)
    assert Foreman.Preview.allow_external_write() == {:error, "refused in preview"}
  end

  test "preview readers require an explicit value of one" do
    System.put_env("PREVIEW", "1")

    for value <- ["", "0", "true"] do
      System.put_env("FOREMAN_PREVIEW_READERS", value)
      refute Foreman.Runtime in Foreman.Role.children("all", [])
    end
  end

  test "reader opt-in does not override runtime disablement" do
    System.put_env("PREVIEW", "1")
    System.put_env("FOREMAN_PREVIEW_READERS", "1")
    Application.put_env(:foreman, :runtime_enabled, false)
    refute Foreman.Runtime in Foreman.Role.children("all", [])
  end

  test "web has a Postgres notifier but no queues, plugins or worker leadership" do
    children =
      Foreman.Role.children("web",
        repo: Foreman.Repo,
        queues: [external_reads: 4],
        plugins: [Oban.Plugins.Pruner]
      )

    assert ForemanWeb.Endpoint in children
    {Oban, opts} = List.keyfind(children, Oban, 0)
    assert opts[:queues] == false
    assert opts[:plugins] == false
    assert opts[:peer] == false
    assert opts[:notifier] == Oban.Notifiers.Postgres
  end

  test "worker runs configured queues without an endpoint; all keeps both" do
    opts = [repo: Foreman.Repo, queues: [external_reads: 4], plugins: [Oban.Plugins.Pruner]]
    worker = Foreman.Role.children("worker", opts)
    refute ForemanWeb.Endpoint in worker
    {Oban, worker_opts} = List.keyfind(worker, Oban, 0)
    assert worker_opts[:queues] == [external_reads: 4]
    assert worker_opts[:plugins] == [Oban.Plugins.Pruner]
    assert worker_opts[:notifier] == Oban.Notifiers.Postgres
    assert Foreman.Role.children("all", opts) == worker ++ [ForemanWeb.Endpoint]
    refute Foreman.Role.endpoint?("worker")
    assert Foreman.Role.endpoint?("web")
  end

  test "unknown roles fail closed instead of enabling all services" do
    assert_raise KeyError, fn -> Foreman.Role.children("typo", []) end
  end

  test "the shipped worker config rescues jobs orphaned by a killed worker" do
    plugins = Config.Reader.read!("config/config.exs", env: :prod)[:foreman][Oban][:plugins]
    {Oban.Plugins.Lifeline, opts} = List.keyfind(plugins, Oban.Plugins.Lifeline, 0)

    # Above every job timeout, so a running job is never rescued mid-flight.
    assert opts[:rescue_after] > Foreman.Merge.MergeJob.timeout(%Oban.Job{})
  end
end
