defmodule Foreman.MergeRequestTest do
  use Foreman.DataCase, async: false
  alias Foreman.{Requests, Overlay}

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

    Overlay.backfill("sample", [%{bead_id: "s-1", status: "open", issue_type: "task"}])

    pr = %{
      "number" => 5,
      "title" => "Bottom",
      "source_branch" => "stack",
      "target_branch" => "main",
      "head_sha" => String.duplicate("a", 40),
      "draft" => false,
      "checks" => "none",
      "mergeable" => "mergeable",
      "state" => "open"
    }

    snapshot = %{"default_branch" => "main", "change_requests" => [pr]}
    Foreman.Forge.Store.replace("sample", "owner/repo", snapshot)
    %{snapshot: snapshot, facts: %{"number" => 5, "expected_sha" => pr["head_sha"]}}
  end

  test "creation refuses missing PR, moved head, and disabled forge", %{facts: facts} do
    assert {:error, :not_found} =
             Requests.ask({"sample", "s-1"}, "merge", %{"facts" => %{facts | "number" => 99}})

    assert {:error, :head_moved} =
             Requests.ask({"sample", "s-1"}, "merge", %{
               "facts" => %{facts | "expected_sha" => String.duplicate("b", 40)}
             })

    Repo.update_all("board_config", set: [config: %{"repos" => []}])

    assert {:error, :forge_disabled} =
             Requests.ask({"sample", "s-1"}, "merge", %{"facts" => facts})
  end

  test "approval requires confirmation and supersedes changed facts", %{
    facts: facts,
    snapshot: snapshot
  } do
    {:ok, request} = Requests.ask({"sample", "s-1"}, "merge", %{"facts" => facts})
    assert {:error, :confirmation_required} = Requests.resolve(request.id, :approve, %{})
    assert Requests.get(request.id).state == "pending"

    Foreman.Forge.Store.replace(
      "sample",
      "owner/repo",
      put_in(snapshot, ["change_requests", Access.at(0), "state"], "closed")
    )

    assert {:ok, %{state: "superseded"}} = Requests.resolve(request.id, :approve, %{})
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "confirmation starts one existing merge action and its outcome resolves once", %{
    facts: facts,
    snapshot: snapshot
  } do
    {:ok, request} = Requests.ask({"sample", "s-1"}, "merge", %{"facts" => facts})
    {:ok, confirmation} = Foreman.Merge.prepare(snapshot, 5)

    assert {:ok, %{state: "executing"} = executing} =
             Requests.confirm_merge(request.id, confirmation, "Ship it")

    action_id = executing.outcome["result"]["action_id"]
    assert is_integer(action_id)
    assert {:error, :invalid} = Requests.confirm_merge(request.id, confirmation)
    assert Repo.aggregate(Oban.Job, :count) == 1
    fake = start_supervised!({Foreman.Forge.Fake, snapshot})
    assert :ok = Foreman.Merge.MergeJob.run(action_id, Foreman.Forge.Fake, server: fake)
    Requests.reconcile_merges()
    Requests.reconcile_merges()

    assert %{
             state: "done",
             note: "Ship it",
             outcome: %{"result" => %{"action_id" => ^action_id, "merge_sha" => sha}}
           } = Requests.get(request.id)

    assert sha == "merge-" <> facts["expected_sha"]
    assert Repo.aggregate(from(e in "request_events", where: e.event == "succeeded"), :count) == 1
  end

  test "creation applies existing eligibility and adapter write capability", %{
    facts: facts,
    snapshot: snapshot
  } do
    for {field, value, reason} <- [
          {"target_branch", "other", :not_bottom},
          {"draft", true, :draft},
          {"checks", "failure", :checks},
          {"mergeable", "unknown", :not_mergeable}
        ] do
      Foreman.Forge.Store.replace(
        "sample",
        "owner/repo",
        put_in(snapshot, ["change_requests", Access.at(0), field], value)
      )

      assert {:error, ^reason} = Requests.ask({"sample", "s-1"}, "merge", %{"facts" => facts})
    end

    previous = Application.get_env(:foreman, :forge_adapter)
    Application.put_env(:foreman, :forge_adapter, Foreman.Test.ReadOnlyForge)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:foreman, :forge_adapter, previous),
        else: Application.delete_env(:foreman, :forge_adapter)
    end)

    assert {:error, :read_only} = Requests.ask({"sample", "s-1"}, "merge", %{"facts" => facts})
  end

  test "pending moved head supersedes through reconciliation", %{facts: facts, snapshot: snapshot} do
    {:ok, request} = Requests.ask({"sample", "s-1"}, "merge", %{"facts" => facts})

    Foreman.Forge.Store.replace(
      "sample",
      "owner/repo",
      put_in(snapshot, ["change_requests", Access.at(0), "head_sha"], String.duplicate("b", 40))
    )

    Requests.reconcile_merges()
    assert %{state: "superseded", outcome: %{"reason" => "head_moved"}} = Requests.get(request.id)
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "ordinary merge and request confirmation share a single audited action", %{
    facts: facts,
    snapshot: snapshot
  } do
    {:ok, request} = Requests.ask({"sample", "s-1"}, "merge", %{"facts" => facts})
    {:ok, confirmation} = Foreman.Merge.prepare(snapshot, 5)
    {:ok, original} = Foreman.Merge.enqueue("sample", "owner/repo", confirmation)
    {:ok, executing} = Requests.confirm_merge(request.id, confirmation)
    assert executing.outcome["result"]["action_id"] == original.id
    assert Repo.aggregate(Oban.Job, :count) == 1
    fake = start_supervised!({Foreman.Forge.Fake, snapshot})
    Foreman.Merge.MergeJob.run(original.id, Foreman.Forge.Fake, server: fake)
    Foreman.Merge.MergeJob.run(original.id, Foreman.Forge.Fake, server: fake)
    Requests.reconcile_merges()
    assert Requests.get(request.id).state == "done"
  end

  test "rescued merge becomes failed without a second job", %{facts: facts, snapshot: snapshot} do
    {:ok, request} = Requests.ask({"sample", "s-1"}, "merge", %{"facts" => facts})
    {:ok, confirmation} = Foreman.Merge.prepare(snapshot, 5)
    {:ok, executing} = Requests.confirm_merge(request.id, confirmation)
    id = executing.outcome["result"]["action_id"]
    Foreman.Merge.claim(id, :merge)

    Repo.update_all(Foreman.Merge.Record,
      set: [claimed_at: DateTime.add(DateTime.utc_now(), -100)]
    )

    Requests.reconcile_merges()

    assert %{state: "failed", outcome: %{"reason" => "outcome_unknown"}} =
             Requests.get(request.id)

    assert is_nil(Foreman.Merge.claim(id, :merge))
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "CLI names the PR and expected head", %{facts: facts} do
    assert {:ok, %{request: %{"facts" => ^facts}}} =
             Foreman.CLI.parse([
               "ask",
               "merge",
               "s-1",
               "--pr",
               "5",
               "--sha",
               facts["expected_sha"]
             ])
  end

  for {scenario, reason} <- [
        {:refused, "checks"},
        {:failed, "unavailable"},
        {:partial, "unavailable"}
      ] do
    test "#{scenario} existing merge outcome resolves the request", context do
      assert_outcome(unquote(scenario), unquote(reason), context)
    end
  end

  defp assert_outcome(scenario, reason, %{facts: facts, snapshot: snapshot}) do
    child = %{
      hd(snapshot["change_requests"])
      | "number" => 6,
        "source_branch" => "child",
        "target_branch" => "stack"
    }

    snapshot =
      if scenario == :partial,
        do: Map.put(snapshot, "change_requests", snapshot["change_requests"] ++ [child]),
        else: snapshot

    Foreman.Forge.Store.replace("sample", "owner/repo", snapshot)
    {:ok, request} = Requests.ask({"sample", "s-1"}, "merge", %{"facts" => facts})
    {:ok, confirmation} = Foreman.Merge.prepare(snapshot, 5)
    {:ok, executing} = Requests.confirm_merge(request.id, confirmation)
    id = executing.outcome["result"]["action_id"]

    live =
      case scenario do
        :refused -> put_in(snapshot, ["change_requests", Access.at(0), "checks"], "failure")
        :failed -> Map.put(snapshot, "merge_error", true)
        :partial -> Map.put(snapshot, "retarget_error", true)
      end

    fake = start_supervised!({Foreman.Forge.Fake, live})
    Foreman.Merge.MergeJob.run(id, Foreman.Forge.Fake, server: fake)

    if scenario == :partial do
      Requests.reconcile_merges()
      assert Requests.get(request.id).state == "executing"
      Foreman.Merge.RetargetJob.run(id, Foreman.Forge.Fake, server: fake)
    end

    Requests.reconcile_merges()
    assert %{state: "failed", outcome: %{"reason" => ^reason}} = Requests.get(request.id)

    if scenario == :partial,
      do:
        assert(
          Requests.get(request.id).outcome["result"]["merge_sha"] ==
            "merge-" <> facts["expected_sha"]
        )

    assert {200, %{"state" => "failed"}} =
             Foreman.AgentCommands.execute(%{"action" => "wait", "id" => request.id})
  end

  test "creation binds an existing PR and exact head to its forge", %{facts: facts} do
    assert {:ok, request} = Requests.ask({"sample", "s-1"}, "merge", %{"facts" => facts})
    assert request.facts == Map.put(facts, "remote", "owner/repo")
    assert request.state == "pending"
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  describe "human merge policy" do
    defp human!(where) do
      config = Foreman.RuntimeState.config().config

      config =
        case where do
          :repo -> put_in(config, ["repos", Access.at(0), "merge_policy"], "human")
          :top -> Map.put(config, "merge_policy", "human")
        end

      Repo.update_all("board_config", set: [config: config])
    end

    test "ask merge is refused at creation with a named reason, per repo or machine-wide", %{
      facts: facts
    } do
      for where <- [:repo, :top] do
        Repo.update_all("board_config",
          set: [
            config: %{
              "repos" => [
                %{
                  "key" => "sample",
                  "forge" => "github",
                  "github" => "owner/repo",
                  "enabled" => true
                }
              ]
            }
          ]
        )

        human!(where)

        assert {:error, :human_merge_policy} =
                 Requests.ask({"sample", "s-1"}, "merge", %{"facts" => facts})
      end

      # What `foreman ask merge` receives from the API: the refusal names its reason.
      assert {422, %{error: :human_merge_policy}} =
               Foreman.AgentCommands.execute(%{
                 "action" => "ask",
                 "repo" => "sample",
                 "id" => "s-1",
                 "request_kind" => "merge",
                 "facts" => facts
               })

      assert Repo.aggregate(Foreman.Requests.Request, :count) == 0
      assert Repo.aggregate(Oban.Job, :count) == 0
    end

    test "a pending ask is superseded when the repo moves to human merge", %{facts: facts} do
      {:ok, request} = Requests.ask({"sample", "s-1"}, "merge", %{"facts" => facts})
      human!(:repo)
      Requests.reconcile_merges()

      assert %{state: "superseded", outcome: %{"reason" => "human_merge_policy"}} =
               Requests.get(request.id)

      assert Repo.aggregate(Oban.Job, :count) == 0
    end

    test "the board cannot enqueue a merge action directly", %{snapshot: snapshot} do
      human!(:repo)
      {:ok, facts} = Foreman.Merge.prepare(snapshot, 5)
      assert {:error, :human_merge_policy} = Foreman.Merge.enqueue("sample", "owner/repo", facts)
      assert Repo.aggregate(Foreman.Merge.Record, :count) == 0
    end

    test "a merge job for a human-merge repo refuses before any forge write", %{
      facts: facts,
      snapshot: snapshot
    } do
      {:ok, request} = Requests.ask({"sample", "s-1"}, "merge", %{"facts" => facts})
      {:ok, confirmation} = Foreman.Merge.prepare(snapshot, 5)
      {:ok, executing} = Requests.confirm_merge(request.id, confirmation)
      id = executing.outcome["result"]["action_id"]
      # The job is forced past creation: the policy changes after confirmation.
      human!(:repo)

      fake = start_supervised!({Foreman.Forge.Fake, snapshot})
      assert :ok = Foreman.Merge.MergeJob.run(id, Foreman.Forge.Fake, server: fake)

      assert %{state: "failed", error: "human_merge_policy", merge_sha: nil} =
               Foreman.Merge.get(id)

      {:ok, live} = Foreman.Forge.Fake.list("owner/repo", server: fake)
      assert [%{"state" => "open"}] = live["change_requests"]
      Requests.reconcile_merges()

      assert %{state: "failed", outcome: %{"reason" => "human_merge_policy"}} =
               Requests.get(request.id)
    end
  end
end
