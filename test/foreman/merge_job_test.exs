defmodule Foreman.MergeJobTest do
  use Foreman.DataCase, async: false
  alias Foreman.Merge
  alias Foreman.Merge.{MergeJob, RetargetJob}

  setup do
    Repo.insert_all("board_config", [
      %{
        id: 1,
        config: %{
          "repos" => [
            %{"key" => "sample", "forge" => "github", "github" => "owner/repo", "enabled" => true}
          ]
        },
        source: "test",
        discovered: [],
        loaded_at: DateTime.utc_now()
      }
    ])

    pr = %{
      "number" => 5,
      "title" => "Bottom",
      "source_branch" => "stack",
      "target_branch" => "main",
      "head_sha" => "confirmed",
      "draft" => false,
      "checks" => "none",
      "mergeable" => "mergeable",
      "state" => "open"
    }

    child = %{
      pr
      | "number" => 6,
        "title" => "Child",
        "source_branch" => "child",
        "target_branch" => "stack",
        "head_sha" => "child-sha"
    }

    snapshot = %{"default_branch" => "main", "change_requests" => [pr, child]}
    fake = start_supervised!({Foreman.Forge.Fake, snapshot})
    %{snapshot: snapshot, fake: fake, pr: pr}
  end

  defp enqueue(snapshot, number \\ 5) do
    {:ok, facts} = Merge.prepare(snapshot, number)
    {:ok, row} = Merge.enqueue("sample", "owner/repo", facts)
    row
  end

  defp preview! do
    previous = System.get_env("PREVIEW")
    System.put_env("PREVIEW", "1")

    on_exit(fn ->
      if previous, do: System.put_env("PREVIEW", previous), else: System.delete_env("PREVIEW")
    end)
  end

  test "approved merge automatically queues the child retarget", %{
    snapshot: snapshot,
    fake: fake
  } do
    row = enqueue(snapshot)
    assert :ok = MergeJob.run(row.id, Foreman.Forge.Fake, server: fake)
    assert %{state: "retargeting"} = Merge.get(row.id)
    assert Repo.exists?(from j in Oban.Job, where: j.worker == "Foreman.Merge.RetargetJob")
    assert :ok = RetargetJob.run(row.id, Foreman.Forge.Fake, server: fake)
    {:ok, actual} = Foreman.Forge.Fake.list("owner/repo", server: fake)
    assert Enum.find(actual["change_requests"], &(&1["number"] == 6))["target_branch"] == "main"
  end

  test "a configured target is used for the merge and the approved follow-up", %{
    snapshot: snapshot,
    fake: fake
  } do
    config =
      put_in(
        Foreman.RuntimeState.config().config,
        ["repos", Access.at(0), "merge_base"],
        "staging"
      )

    Repo.update_all("board_config", set: [config: config])
    snapshot = put_in(snapshot, ["change_requests", Access.at(0), "target_branch"], "staging")
    Agent.update(fake, fn _ -> snapshot end)
    {:ok, facts} = Merge.prepare(snapshot, 5, "sample")
    assert facts["default_branch"] == "staging"
    {:ok, row} = Merge.enqueue("sample", "owner/repo", facts)
    :ok = MergeJob.run(row.id, Foreman.Forge.Fake, server: fake)
    assert %{state: "retargeting"} = Merge.get(row.id)
    :ok = RetargetJob.run(row.id, Foreman.Forge.Fake, server: fake)
    assert %{state: "merged"} = Merge.get(row.id)
    {:ok, actual} = Foreman.Forge.Fake.list("owner/repo", server: fake)

    assert Enum.find(actual["change_requests"], &(&1["number"] == 6))["target_branch"] ==
             "staging"
  end

  test "preview refuses a queued merge and leaves forge reads available", %{
    snapshot: snapshot,
    fake: fake
  } do
    row = enqueue(snapshot)
    preview!()
    assert :ok = MergeJob.run(row.id, Foreman.Forge.Fake, server: fake)
    assert %{state: "failed", error: "refused in preview", merge_sha: nil} = Merge.get(row.id)
    assert {:ok, ^snapshot} = Foreman.Forge.Fake.list("owner/repo", server: fake)
    refute Repo.exists?(from j in Oban.Job, where: j.worker == "Foreman.Merge.RetargetJob")
  end

  test "preview refuses a copied retarget without erasing merge evidence", %{
    snapshot: snapshot,
    fake: fake
  } do
    row = enqueue(snapshot)
    assert :ok = MergeJob.run(row.id, Foreman.Forge.Fake, server: fake)
    {:ok, merged_snapshot} = Foreman.Forge.Fake.list("owner/repo", server: fake)
    preview!()
    assert :ok = RetargetJob.run(row.id, Foreman.Forge.Fake, server: fake)

    assert %{state: "failed", error: "refused in preview", merge_sha: "merge-confirmed"} =
             Merge.get(row.id)

    assert {:ok, ^merged_snapshot} = Foreman.Forge.Fake.list("owner/repo", server: fake)
  end

  test "preview merge perform refuses without a credential service", %{snapshot: snapshot} do
    row = enqueue(snapshot)
    preview!()
    assert :ok = MergeJob.perform(%Oban.Job{args: %{"action_id" => row.id}})
    assert %{state: "failed", error: "refused in preview"} = Merge.get(row.id)
  end

  test "preview retarget perform refuses without a credential service", %{
    snapshot: snapshot,
    fake: fake
  } do
    row = enqueue(snapshot)
    :ok = MergeJob.run(row.id, Foreman.Forge.Fake, server: fake)
    preview!()
    assert :ok = RetargetJob.perform(%Oban.Job{args: %{"action_id" => row.id}})

    assert %{state: "failed", error: "refused in preview", merge_sha: "merge-confirmed"} =
             Merge.get(row.id)
  end

  test "durable audit precedes write; merge and retarget do not replay", %{
    snapshot: snapshot,
    fake: fake
  } do
    row = enqueue(snapshot)
    assert row.state == "merging"
    assert row.requested_by == "local_ui"
    assert :ok = MergeJob.run(row.id, Foreman.Forge.Fake, server: fake)
    assert %{state: "retargeting", merge_sha: "merge-confirmed"} = Merge.get(row.id)

    assert :ok = MergeJob.run(row.id, Foreman.Forge.Fake, server: fake)
    assert :ok = RetargetJob.run(row.id, Foreman.Forge.Fake, server: fake)
    assert :ok = RetargetJob.run(row.id, Foreman.Forge.Fake, server: fake)
    assert %{state: "merged"} = Merge.get(row.id)
    {:ok, actual} = Foreman.Forge.Fake.list("owner/repo", server: fake)
    assert Enum.find(actual["change_requests"], &(&1["number"] == 6))["target_branch"] == "main"
    assert {:ok, again} = Merge.enqueue("sample", "owner/repo", row.facts)
    assert again.id == row.id
  end

  test "the job refuses a top PR even when enqueued without the UI guard", %{
    snapshot: snapshot,
    fake: fake
  } do
    facts = %{
      "pr" => List.last(snapshot["change_requests"]),
      "child" => nil,
      "default_branch" => "main"
    }

    {:ok, row} = Merge.enqueue("sample", "owner/repo", facts)
    MergeJob.run(row.id, Foreman.Forge.Fake, server: fake)
    assert %{state: "failed", error: "not_bottom", merge_sha: nil} = Merge.get(row.id)
  end

  test "a leaf completes without retarget; disabled writes never reach the forge", %{
    snapshot: snapshot,
    fake: fake
  } do
    row = enqueue(snapshot)
    MergeJob.run(row.id, Foreman.Test.ReadOnlyForge, [])
    assert %{state: "failed", error: "read_only"} = Merge.get(row.id)
    Repo.delete_all("merge_actions")
    leaf = %{snapshot | "change_requests" => [hd(snapshot["change_requests"])]}
    Agent.update(fake, fn _ -> leaf end)
    row = enqueue(leaf)
    MergeJob.run(row.id, Foreman.Forge.Fake, server: fake)
    assert %{state: "merged", error: nil, merge_sha: "merge-confirmed"} = Merge.get(row.id)
    refute Repo.exists?(from j in Oban.Job, where: j.worker == "Foreman.Merge.RetargetJob")
  end

  test "a moved head is identified even while GitHub recomputes mergeability", %{
    snapshot: snapshot,
    fake: fake
  } do
    row = enqueue(snapshot)

    Agent.update(fake, fn s ->
      update_in(
        s,
        ["change_requests", Access.at(0)],
        &Map.merge(&1, %{"head_sha" => "moved", "mergeable" => "unknown"})
      )
    end)

    MergeJob.run(row.id, Foreman.Forge.Fake, server: fake)
    assert %{state: "failed", error: "head_moved", merge_sha: nil} = Merge.get(row.id)
  end

  test "the live GitHub unknown-mergeability response still identifies the moved head" do
    opts = [token: "test", plug: {Req.Test, __MODULE__}]

    initial =
      File.read!("test/fixtures/forge/live-merge/first-initial-list.json") |> Jason.decode!()

    moved = File.read!("test/fixtures/forge/live-merge/first-moved-list.json") |> Jason.decode!()
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, initial["response"]))
    {:ok, snapshot} = Foreman.Forge.GitHub.list("owner/repo", opts)
    row = enqueue(snapshot, 1)

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/graphql"
      Req.Test.json(conn, moved["response"])
    end)

    MergeJob.run(row.id, Foreman.Forge.GitHub, opts)
    assert %{state: "failed", error: "head_moved", merge_sha: nil} = Merge.get(row.id)
  end

  test "job re-reads and refuses a moved head", %{snapshot: snapshot, fake: fake} do
    row = enqueue(snapshot)

    Agent.update(fake, fn s ->
      put_in(s, ["change_requests", Access.at(0), "head_sha"], "moved")
    end)

    assert :ok = MergeJob.run(row.id, Foreman.Forge.Fake, server: fake)
    assert %{state: "failed", error: "head_moved", merge_sha: nil} = Merge.get(row.id)
  end

  test "all safety rules are enforced by the job, not cached UI", %{
    snapshot: snapshot,
    fake: fake
  } do
    for {field, value, reason} <- [
          {"draft", true, "draft"},
          {"checks", "pending", "checks"},
          {"mergeable", "unknown", "not_mergeable"},
          {"target_branch", "detached", "not_bottom"},
          {"state", "closed", "not_open"}
        ] do
      Repo.delete_all("merge_actions")
      row = enqueue(snapshot)

      Agent.update(fake, fn _ ->
        put_in(snapshot, ["change_requests", Access.at(0), field], value)
      end)

      assert :ok = MergeJob.run(row.id, Foreman.Forge.Fake, server: fake)
      assert %{state: "failed", error: ^reason, merge_sha: nil} = Merge.get(row.id)
    end

    assert {:error, :not_bottom} = Merge.prepare(snapshot, 6)
  end

  test "weaker capability re-reads immediately; absent retarget records a manual step", %{
    snapshot: snapshot,
    fake: fake
  } do
    row = enqueue(snapshot)
    MergeJob.run(row.id, Foreman.Test.WeakForge, server: fake, observer: self())
    assert_receive :read
    assert_receive :read
    assert_receive :merge

    assert %{state: "merged", error: "manual_retarget", merge_sha: "merge-confirmed"} =
             Merge.get(row.id)

    refute Repo.exists?(from j in Oban.Job, where: j.worker == "Foreman.Merge.RetargetJob")
  end

  test "ambiguous result is not automatically retried", %{snapshot: snapshot, fake: fake} do
    row = enqueue(snapshot)
    MergeJob.run(row.id, Foreman.Test.AmbiguousForge, server: fake, observer: self())
    assert_receive :merge
    assert %{state: "failed", error: "outcome_unknown"} = Merge.get(row.id)
    MergeJob.run(row.id, Foreman.Test.AmbiguousForge, server: fake, observer: self())
    refute_received :merge
  end

  test "cancelled or timed-out job reconciles durable action without replay", %{
    snapshot: snapshot
  } do
    row = enqueue(snapshot)

    Repo.update_all(from(j in Oban.Job, where: j.worker == "Foreman.Merge.MergeJob"),
      set: [state: "discarded"]
    )

    assert %{state: "failed", error: "outcome_unknown"} = Merge.reconcile(row)
  end

  test "a dead worker's claimed action times out even if Oban never updates or prunes its job", %{
    snapshot: snapshot
  } do
    row = enqueue(snapshot)
    Merge.claim(row.id, :merge)
    old = DateTime.add(DateTime.utc_now(), -121)
    Repo.update_all(Foreman.Merge.Record, set: [claimed_at: old])
    Repo.delete_all(Oban.Job)
    assert %{state: "failed", error: "outcome_unknown"} = Merge.reconcile(Merge.get(row.id))
  end

  test "losing an audit transition cannot enqueue a retarget", %{snapshot: snapshot} do
    row = enqueue(snapshot)
    Merge.advance(row, :job_timeout, Foreman.Forge.Fake.capabilities(), error: "outcome_unknown")
    Merge.advance(row, :merge_ok, Foreman.Forge.Fake.capabilities(), merge_sha: "late")
    refute Repo.exists?(from j in Oban.Job, where: j.worker == "Foreman.Merge.RetargetJob")
  end

  test "configuration and confirmed child changes block the write", %{
    snapshot: snapshot,
    fake: fake
  } do
    row = enqueue(snapshot)

    Agent.update(fake, fn s ->
      put_in(s, ["change_requests", Access.at(1), "target_branch"], "main")
    end)

    MergeJob.run(row.id, Foreman.Forge.Fake, server: fake)
    assert %{state: "failed", error: "stack_changed"} = Merge.get(row.id)
    Repo.delete_all("merge_actions")
    row = enqueue(snapshot)
    Repo.update_all("board_config", set: [config: %{"repos" => []}])
    MergeJob.run(row.id, Foreman.Forge.Fake, server: fake)
    assert %{state: "failed", error: "config_changed"} = Merge.get(row.id)
  end

  test "retarget refuses a child whose base has been moved elsewhere", %{
    snapshot: snapshot,
    fake: fake
  } do
    row = enqueue(snapshot)
    MergeJob.run(row.id, Foreman.Forge.Fake, server: fake)

    Agent.update(fake, fn s ->
      put_in(s, ["change_requests", Access.at(1), "target_branch"], "elsewhere")
    end)

    RetargetJob.run(row.id, Foreman.Forge.Fake, server: fake)

    assert %{state: "failed", error: "child_changed", merge_sha: "merge-confirmed"} =
             Merge.get(row.id)
  end

  test "partial failure retains merge evidence and never remerges", %{
    snapshot: snapshot,
    fake: fake
  } do
    row = enqueue(snapshot)
    MergeJob.run(row.id, Foreman.Forge.Fake, server: fake)
    Agent.update(fake, &Map.put(&1, "retarget_error", true))
    RetargetJob.run(row.id, Foreman.Forge.Fake, server: fake)

    assert %{state: "failed", merge_sha: "merge-confirmed", error: "unavailable"} =
             Merge.get(row.id)

    MergeJob.run(row.id, Foreman.Forge.Fake, server: fake)
    assert Merge.get(row.id).merge_sha == "merge-confirmed"
  end
end
