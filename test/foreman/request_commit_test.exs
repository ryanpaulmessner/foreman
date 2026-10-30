defmodule Foreman.RequestCommitTest do
  use ExUnit.Case, async: false
  alias Foreman.{Overlay, Repo, Requests}

  setup do
    repo = "request-race-#{System.unique_integer([:positive])}"
    key = {repo, "ticket"}

    on_exit(fn ->
      unboxed(fn ->
        Repo.query!(
          "DELETE FROM request_events WHERE request_id IN (SELECT id FROM approval_requests WHERE repo_key=$1)",
          [repo]
        )

        Repo.query!(
          "DELETE FROM overlay_effects WHERE event_id IN (SELECT id FROM stage_events WHERE repo_key=$1)",
          [repo]
        )

        for table <- ~w(approval_requests agent_notes sessions stage_events tickets),
            do: Repo.query!("DELETE FROM #{table} WHERE repo_key=$1", [repo])
      end)
    end)

    unboxed(fn ->
      Overlay.backfill(repo, [%{bead_id: "ticket", issue_type: :task, status: :open}])
    end)

    %{key: key}
  end

  test "concurrent answer and decline commit exactly one outcome", %{key: key} do
    {:ok, request} =
      unboxed(fn ->
        Requests.ask(key, "decision", %{
          "facts" => Foreman.DecisionFacts.valid(%{"question" => "Which?"})
        })
      end)

    results =
      race([
        fn -> Requests.resolve(request.id, :answer, %{"answer" => "A"}) end,
        fn -> Requests.resolve(request.id, :decline, %{"note" => "No"}) end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :invalid}, &1)) == 1

    unboxed(fn ->
      assert Requests.get(request.id).state in ["answered", "declined"]

      assert %{rows: [[2]]} =
               Repo.query!("SELECT count(*) FROM request_events WHERE request_id=$1", [
                 Ecto.UUID.dump!(request.id)
               ])
    end)
  end

  for kind <- ["push", "open_pr"] do
    @kind kind
    test "independent worker connections obtain exactly one durable #{kind} start", %{
      key: {repo, id}
    } do
      request =
        unboxed(fn ->
          Repo.insert!(%Foreman.Requests.Request{
            repo_key: repo,
            bead_id: id,
            kind: @kind,
            actor: "pi",
            state: "approved",
            facts: %{}
          })
        end)

      results =
        race([
          fn -> Requests.resolve(request.id, :start, %{}) end,
          fn -> Requests.resolve(request.id, :start, %{}) end
        ])

      assert Enum.count(results, &match?({:ok, %{state: "executing"}}, &1)) == 1
      assert Enum.count(results, &match?({:error, :invalid}, &1)) == 1

      unboxed(fn ->
        assert %{rows: [[1]]} =
                 Repo.query!(
                   "SELECT count(*) FROM request_events WHERE request_id=$1 AND event='start'",
                   [Ecto.UUID.dump!(request.id)]
                 )
      end)
    end
  end

  test "double merge confirmation and competing outcome observations commit once", %{
    key: {repo, _} = key
  } do
    remote = "owner/" <> repo

    snapshot = %{
      "default_branch" => "main",
      "change_requests" => [
        %{
          "number" => 5,
          "head_sha" => String.duplicate("a", 40),
          "source_branch" => "feature",
          "target_branch" => "main",
          "state" => "open",
          "draft" => false,
          "checks" => "none",
          "mergeable" => "mergeable"
        }
      ]
    }

    {:ok, facts} = Foreman.Merge.prepare(snapshot, 5)

    request =
      unboxed(fn ->
        Repo.insert_all("board_config", [
          %{
            id: 1,
            config: %{
              "repos" => [
                %{"key" => repo, "forge" => "github", "github" => remote, "enabled" => true}
              ]
            },
            source: "test",
            discovered: [],
            loaded_at: DateTime.utc_now()
          }
        ])

        Foreman.Forge.Store.replace(repo, remote, snapshot)

        {:ok, request} =
          Requests.ask(key, "merge", %{
            "facts" => %{"number" => 5, "expected_sha" => String.duplicate("a", 40)}
          })

        request
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.query!(
          "DELETE FROM oban_jobs WHERE args->>'action_id' IN (SELECT id::text FROM merge_actions WHERE repo_key=$1)",
          [repo]
        )

        Repo.query!("DELETE FROM merge_actions WHERE repo_key=$1", [repo])
        Repo.query!("DELETE FROM forge_snapshots WHERE repo_key=$1", [repo])
        Repo.delete_all("board_config")
      end)
    end)

    results =
      race([
        fn -> Requests.confirm_merge(request.id, facts) end,
        fn -> Requests.confirm_merge(request.id, facts) end
      ])

    assert Enum.count(results, &match?({:ok, %{state: "executing"}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :invalid}, &1)) == 1

    action =
      unboxed(fn ->
        action = Foreman.Merge.get(Requests.get(request.id).outcome["result"]["action_id"])

        assert %{rows: [[1]]} =
                 Repo.query!("SELECT count(*) FROM oban_jobs WHERE args->>'action_id'=$1", [
                   to_string(action.id)
                 ])

        action
      end)

    # Competing observations cannot replace the first terminal outcome.
    results =
      race([
        fn ->
          Requests.resolve(request.id, :succeeded, %{"result" => %{"action_id" => action.id}})
        end,
        fn -> Requests.resolve(request.id, :failed, %{"reason" => "late failure"}) end
      ])

    assert length(results) == 2

    unboxed(fn ->
      assert Requests.get(request.id).state in ["done", "failed"]

      assert %{rows: [[1]]} =
               Repo.query!(
                 "SELECT count(*) FROM request_events WHERE request_id=$1 AND event IN ('succeeded','failed')",
                 [Ecto.UUID.dump!(request.id)]
               )
    end)
  end

  test "a decision accepted before ticket completion stays pending", %{key: key} do
    race([
      fn ->
        Requests.ask(key, "decision", %{
          "facts" => Foreman.DecisionFacts.valid(%{"question" => "Which?"})
        })
      end,
      fn -> Overlay.apply_event(key, :bead_closed) end
    ])

    unboxed(fn ->
      assert Overlay.get(key).stage == :done
      assert Enum.all?(Requests.for_ticket(key), &(&1.state == "pending"))
    end)
  end

  defp race(funs) do
    parent = self()

    for {fun, index} <- Enum.with_index(funs) do
      start_supervised!(
        {Task,
         fn ->
           send(parent, {:ready, self()})

           receive do
             :go -> send(parent, {:result, unboxed(fun)})
           end
         end},
        id: index
      )
    end

    pids =
      for _ <- funs do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :go))

    for _ <- funs do
      assert_receive {:result, result}, 3_000
      result
    end
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
