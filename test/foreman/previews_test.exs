defmodule Foreman.PreviewsTest do
  use Foreman.DataCase, async: false
  alias Foreman.Previews

  setup do
    Foreman.Overlay.backfill("preview-test", [%{bead_id: "a", status: "open", issue_type: "task"}])

    key = {"preview-test", "a"}

    Foreman.Overlay.apply_event(
      key,
      {:dispatch, %{window: "preview-test", workdir: System.tmp_dir!()}}
    )

    {:ok, key: key}
  end

  test "start is explicit, worker observes running and bounded logs, stop removes registry", %{
    key: key
  } do
    assert Previews.for_ticket(key).state == :none
    assert :ok = Previews.reconcile(Foreman.FakeDevserve)
    assert Previews.for_ticket(key).state == :none
    assert {:ok, _} = Previews.start(key)
    assert Previews.for_ticket(key).state == :starting
    assert :ok = Previews.reconcile(Foreman.FakeDevserve)

    assert %{
             state: :running,
             metadata: %{"url" => "http://127.0.0.1:4888"},
             logs: "Listening on localhost\n"
           } = Previews.for_ticket(key)

    assert {:ok, _} = Previews.stop(Previews.for_ticket(key).id)
    assert :ok = Previews.reconcile(Foreman.FakeDevserve)
    assert Previews.for_ticket(key).state == :stopped
    assert {:ok, []} = Foreman.FakeDevserve.list()
  end

  test "terminal stages stop and drop, including a stage change while up is in flight", %{
    key: key
  } do
    for event <- [:bead_closed, :abandon, :cr_merged] do
      Repo.update_all("tickets", set: [stage: "pr_open"])
      assert {:ok, _} = Previews.start(key)

      Process.put(:devserve_up, fn ->
        assert {:ok, _} = Foreman.Overlay.apply_event(key, event)
        assert Previews.for_ticket(key).state == :stopping
        assert {:error, :unavailable} = Previews.start(key)
      end)

      assert :ok = Previews.reconcile(Foreman.FakeDevserve)
      assert Previews.for_ticket(key).state == :stopped
      assert {:ok, []} = Foreman.FakeDevserve.list()
    end
  end

  test "a ticket closed with its PR open keeps its preview until the PR merges", %{key: key} do
    Repo.update_all("tickets", set: [stage: "pr_open"])
    assert {:ok, _} = Foreman.Overlay.apply_event(key, {:cr_opened, %{number: 42}})
    assert {:ok, %{stage: :done}} = Foreman.Overlay.apply_event(key, :bead_closed)

    assert {:ok, _} = Previews.start(key)
    assert :ok = Previews.reconcile(Foreman.FakeDevserve)
    assert Previews.for_ticket(key).state == :running

    assert {:ok, %{stage: :done}} = Foreman.Overlay.apply_event(key, {:cr_merged, %{number: 42}})
    assert Previews.for_ticket(key).state == :stopping
    assert :ok = Previews.reconcile(Foreman.FakeDevserve)
    assert Previews.for_ticket(key).state == :stopped
    assert {:ok, []} = Foreman.FakeDevserve.list()
    assert {:error, :unavailable} = Previews.start(key)
  end

  test "orphan registry entries are listed and stoppable without touching main units" do
    Process.put(:devserve_previews, [
      %{
        "unit" => "devserve-orphan.service",
        "worktree" => "/vanished/preview",
        "state" => "running",
        "missing" => true,
        "url" => "http://127.0.0.1:4888"
      }
    ])

    assert :ok = Previews.reconcile(Foreman.FakeDevserve)
    assert [%{state: :running} = orphan] = Previews.orphans()
    assert {:ok, _} = Previews.stop(orphan.id)
    assert :ok = Previews.reconcile(Foreman.FakeDevserve)
    assert Previews.orphans() == []
    assert {:ok, []} = Foreman.FakeDevserve.list()
  end

  test "an externally starting orphan that vanishes is never restarted" do
    Process.put(:devserve_previews, [
      %{
        "unit" => "devserve-orphan.service",
        "worktree" => "/vanished/preview",
        "state" => "starting",
        "missing" => true,
        "url" => "http://127.0.0.1:4888"
      }
    ])

    Previews.reconcile(Foreman.FakeDevserve)
    Process.put(:devserve_previews, [])
    Process.put(:devserve_up, fn -> flunk("unexpected automatic start") end)
    assert :ok = Previews.reconcile(Foreman.FakeDevserve)
    assert {:ok, []} = Foreman.FakeDevserve.list()
  end

  test "a stopped worktree can be used by a later ticket", %{key: key} do
    Previews.start(key)
    Previews.reconcile(Foreman.FakeDevserve)
    Previews.stop(Previews.for_ticket(key).id)
    Previews.reconcile(Foreman.FakeDevserve)

    Foreman.Overlay.backfill("preview-test", [
      %{bead_id: "next", status: "open", issue_type: "task"}
    ])

    next = {"preview-test", "next"}
    Foreman.Overlay.apply_event(next, {:dispatch, %{window: "next", workdir: System.tmp_dir!()}})
    assert {:ok, _} = Previews.start(next)
    assert %{bead_id: "next", state: :starting} = Previews.for_ticket(next)
  end

  test "a removed ticket leaves its preview visible as an orphan", %{key: key} do
    Previews.start(key)
    Previews.reconcile(Foreman.FakeDevserve)
    Repo.update_all("tickets", set: [orphaned_at: DateTime.utc_now()])
    assert [%{state: :running}] = Previews.orphans()
  end

  test "failed database ownership check retains a stoppable entry for retry", %{key: key} do
    Previews.start(key)
    Previews.reconcile(Foreman.FakeDevserve)
    Previews.stop(Previews.for_ticket(key).id)
    Process.put(:devserve_drop_failure, true)
    Previews.reconcile(Foreman.FakeDevserve)
    assert %{state: :stopping, error: "database ownership mismatch"} = Previews.for_ticket(key)
    assert {:ok, [_]} = Foreman.FakeDevserve.list()
    Process.delete(:devserve_drop_failure)
    Previews.reconcile(Foreman.FakeDevserve)
    assert Previews.for_ticket(key).state == :stopped
  end

  test "preview copies refuse commands and queued jobs", %{key: key} do
    old = System.get_env("PREVIEW")
    System.put_env("PREVIEW", "1")

    on_exit(fn ->
      if old, do: System.put_env("PREVIEW", old), else: System.delete_env("PREVIEW")
    end)

    assert {:error, :unavailable} = Previews.start(key)
    assert {:error, :preview_read_only} = Previews.stop(123)
    assert {:error, "refused in preview"} = Previews.Job.perform(%Oban.Job{})
    assert Previews.for_ticket(key).state == :none
  end

  test "devserve JSON drives observations without cancelling a pending stop" do
    assert Previews.observation(%{"state" => "running"}) == :running
    assert Previews.observation(%{"state" => "failed"}) == :failed
    assert Previews.observation(%{"state" => "stopped"}) == :stopped
    assert {:starting, []} = Previews.Machine.step(:none, :start, %{})
    assert {:running, []} = Previews.Machine.step(:starting, :running, %{})
    assert {:stopping, []} = Previews.Machine.step(:running, :stop, %{})
    assert {:stopping, []} = Previews.Machine.step(:stopping, :running, %{})
    assert {:stopped, []} = Previews.Machine.step(:stopping, :stopped, %{})
    assert {:error, _} = Previews.Machine.step(:stopping, :start, %{})
  end
end
