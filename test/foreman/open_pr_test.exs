defmodule Foreman.OpenPrTest do
  use Foreman.DataCase, async: false
  alias Foreman.{Overlay, Requests}
  @sha String.duplicate("a", 40)

  setup do
    Repo.insert_all("board_config", [
      %{
        id: 1,
        config: %{
          "repos" => [
            %{
              "key" => "sample",
              "path" => "/tmp/unused",
              "forge" => "github",
              "github" => "owner/repo",
              "enabled" => true
            }
          ]
        },
        source: "test",
        discovered: [],
        loaded_at: DateTime.utc_now()
      }
    ])

    Overlay.backfill("sample", [%{bead_id: "s-1", status: "open", issue_type: "task"}])

    fake =
      start_supervised!(
        {Foreman.Forge.Fake,
         %{
           "default_branch" => "main",
           "branches" => %{"feature" => @sha, "main" => String.duplicate("b", 40)},
           "change_requests" => []
         }}
      )

    {:ok, snapshot} = Foreman.Forge.Fake.list("owner/repo", server: fake)
    Foreman.Forge.Store.replace("sample", "owner/repo", snapshot)
    old_adapter = Application.get_env(:foreman, :forge_adapter)
    old_options = Application.get_env(:foreman, :forge_options)
    Application.put_env(:foreman, :forge_adapter, Foreman.Forge.Fake)
    Application.put_env(:foreman, :forge_options, server: fake)

    on_exit(fn ->
      if old_adapter,
        do: Application.put_env(:foreman, :forge_adapter, old_adapter),
        else: Application.delete_env(:foreman, :forge_adapter)

      if old_options,
        do: Application.put_env(:foreman, :forge_options, old_options),
        else: Application.delete_env(:foreman, :forge_options)
    end)

    %{
      fake: fake,
      facts: %{
        "head_branch" => "feature",
        "expected_sha" => @sha,
        "base_branch" => "main",
        "title" => "s-1 Exact title",
        "body" => "Exact body\n"
      }
    }
  end

  defp ask(facts), do: Requests.ask({"sample", "s-1"}, "open_pr", %{"facts" => facts})
  defp committed, do: Repo.update_all("tickets", set: [stage: "committed"])

  test "creation binds remote and exact facts, refusing forge none", %{facts: facts} do
    committed()
    assert {:ok, request} = ask(facts)
    assert request.facts == Map.put(facts, "remote", "owner/repo")

    config =
      Foreman.RuntimeState.config().config |> put_in(["repos", Access.at(0), "forge"], "none")

    Repo.update_all("board_config", set: [config: config])
    assert {:error, :forge_disabled} = ask(facts)
  end

  test "creation checks observed head, base and absence of an open PR", %{
    facts: facts,
    fake: fake
  } do
    committed()
    assert {:error, :head_moved} = ask(Map.put(facts, "expected_sha", String.duplicate("c", 40)))
    assert {:error, :head_missing} = ask(Map.put(facts, "head_branch", "missing"))
    assert {:error, :base_missing} = ask(Map.put(facts, "base_branch", "missing"))
    assert {:error, :invalid_facts} = ask(Map.put(facts, "title", "  "))
    assert {:error, :invalid_facts} = ask(Map.put(facts, "body", nil))

    Agent.update(
      fake,
      &Map.put(&1, "change_requests", [
        %{"number" => 1, "source_branch" => "feature", "state" => "open"}
      ])
    )

    {:ok, snapshot} = Foreman.Forge.Fake.list("owner/repo", server: fake)
    Foreman.Forge.Store.replace("sample", "owner/repo", snapshot)
    assert {:error, :already_open} = ask(facts)
  end

  test "approved worker opens once; only the next forge observation advances the ticket", %{
    facts: facts,
    fake: fake
  } do
    committed()
    {:ok, request} = ask(facts)
    assert {:ok, %{state: "approved"}} = Requests.resolve(request.id, :approve, %{})

    assert [%Oban.Job{args: %{"request_id" => id}, queue: "external_writes", max_attempts: 1}] =
             Repo.all(Oban.Job)

    assert id == request.id
    assert :ok = Foreman.Requests.OpenPrJob.run(request.id)
    assert %{state: "done"} = Requests.get(request.id)
    assert Overlay.get({"sample", "s-1"}).stage == :committed
    assert :ok = Foreman.Requests.OpenPrJob.run(request.id)
    {:ok, snapshot} = Foreman.Forge.Fake.list("owner/repo", server: fake)
    assert [pr] = snapshot["change_requests"]
    assert pr["title"] == facts["title"]
    assert pr["body"] == facts["body"]
    Foreman.Forge.Store.replace("sample", "owner/repo", snapshot)
    assert Overlay.get({"sample", "s-1"}).stage == :pr_open
    assert Repo.aggregate(from(e in "request_events", where: e.event == "start"), :count) == 1
  end

  test "head movement before approval supersedes without enqueueing", %{facts: facts, fake: fake} do
    committed()
    {:ok, request} = ask(facts)
    Agent.update(fake, &put_in(&1, ["branches", "feature"], String.duplicate("c", 40)))
    {:ok, snapshot} = Foreman.Forge.Fake.list("owner/repo", server: fake)
    Foreman.Forge.Store.replace("sample", "owner/repo", snapshot)
    assert {:ok, %{state: "superseded"}} = Requests.resolve(request.id, :approve, %{})
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  for {change, reason} <- [
        {:head, "head_moved"},
        {:missing_head, "head_missing"},
        {:base, "base_missing"},
        {:existing, "already_open"}
      ] do
    @change change
    @reason reason
    test "job rechecks #{change} after approval", %{facts: facts, fake: fake} do
      committed()
      {:ok, request} = ask(facts)
      Requests.resolve(request.id, :approve, %{})

      Agent.update(fake, fn snapshot ->
        case @change do
          :head ->
            put_in(snapshot, ["branches", "feature"], String.duplicate("c", 40))

          :missing_head ->
            Map.update!(snapshot, "branches", &Map.delete(&1, "feature"))

          :base ->
            Map.update!(snapshot, "branches", &Map.delete(&1, "main"))

          :existing ->
            Map.put(snapshot, "change_requests", [
              %{"number" => 9, "source_branch" => "feature", "state" => "open"}
            ])
        end
      end)

      Foreman.Requests.OpenPrJob.run(request.id)
      assert %{state: "failed", outcome: %{"reason" => @reason}} = Requests.get(request.id)
      {:ok, snapshot} = Foreman.Forge.Fake.list("owner/repo", server: fake)
      assert length(snapshot["change_requests"]) == if(@change == :existing, do: 1, else: 0)
    end
  end

  test "ambiguous successful write and rescue never create twice", %{facts: facts, fake: fake} do
    committed()
    {:ok, request} = ask(facts)
    Requests.resolve(request.id, :approve, %{})
    Application.put_env(:foreman, :forge_adapter, Foreman.Test.AmbiguousForge)
    Foreman.Requests.OpenPrJob.run(request.id)

    assert %{state: "failed", outcome: %{"reason" => "outcome_unknown"}} =
             Requests.get(request.id)

    Foreman.Requests.OpenPrJob.run(request.id)
    {:ok, snapshot} = Foreman.Forge.Fake.list("owner/repo", server: fake)
    assert length(snapshot["change_requests"]) == 1
    assert Overlay.get({"sample", "s-1"}).stage == :committed
  end

  test "reconciliation supersedes moved heads and rescues pruned executing jobs", %{
    facts: facts,
    fake: fake
  } do
    committed()
    {:ok, pending} = ask(facts)
    {:ok, executing} = ask(facts)
    Requests.resolve(executing.id, :approve, %{})
    Requests.resolve(executing.id, :start, %{})
    Repo.delete_all(Oban.Job)
    Agent.update(fake, &put_in(&1, ["branches", "feature"], String.duplicate("c", 40)))
    Requests.reconcile_open_prs()
    assert %{state: "superseded"} = Requests.get(pending.id)

    assert %{state: "failed", outcome: %{"reason" => "outcome unknown"}} =
             Requests.get(executing.id)

    Foreman.Requests.OpenPrJob.run(executing.id)
    {:ok, snapshot} = Foreman.Forge.Fake.list("owner/repo", server: fake)
    assert snapshot["change_requests"] == []
  end

  test "CLI preserves body-file bytes and names every PR fact" do
    path = Path.join(System.tmp_dir!(), "open-pr-body-#{System.unique_integer([:positive])}")
    File.write!(path, "Body\n\nExact.\n")
    on_exit(fn -> File.rm!(path) end)

    assert {:ok, %{request: request}} =
             Foreman.CLI.parse([
               "ask",
               "open_pr",
               "s-1",
               "--project",
               "sample",
               "--head",
               "feature",
               "--sha",
               @sha,
               "--base",
               "main",
               "--title",
               "Exact title",
               "--body-file",
               path
             ])

    assert request["facts"] == %{
             "head_branch" => "feature",
             "expected_sha" => @sha,
             "base_branch" => "main",
             "title" => "Exact title",
             "body" => "Body\n\nExact.\n"
           }

    assert ExUnit.CaptureIO.capture_io(fn ->
             assert Foreman.CLI.run(["ask", "open_pr", "s-1", "--body-file", path <> "-absent"]) ==
                      0
           end) =~ "warning:"
  end

  test "preview refuses before any forge call", %{facts: facts} do
    committed()
    {:ok, request} = ask(facts)
    Requests.resolve(request.id, :approve, %{})
    old = System.get_env("PREVIEW")
    System.put_env("PREVIEW", "1")

    on_exit(fn ->
      if old, do: System.put_env("PREVIEW", old), else: System.delete_env("PREVIEW")
    end)

    Application.put_env(:foreman, :forge_adapter, Foreman.Test.ReadOnlyForge)
    Application.delete_env(:foreman, :forge_options)
    Foreman.Requests.OpenPrJob.run(request.id)

    assert %{state: "failed", outcome: %{"reason" => "refused in preview"}} =
             Requests.get(request.id)
  end

  test "killed after remote create, rescue cannot repeat the write", %{facts: facts, fake: fake} do
    committed()
    {:ok, request} = ask(facts)
    Requests.resolve(request.id, :approve, %{})
    Application.put_env(:foreman, :forge_adapter, Foreman.Test.BlockingCreateForge)
    Application.put_env(:foreman, :forge_options, server: fake, observer: self())
    supervisor = start_supervised!({Task.Supervisor, []})

    {:ok, pid} =
      Task.Supervisor.start_child(supervisor, fn ->
        receive do
          :start -> Foreman.Requests.OpenPrJob.run(request.id)
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    ref = Process.monitor(pid)
    send(pid, :start)
    assert_receive {:created, ^pid}, 3_000
    assert Requests.get(request.id).state == "executing"
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    Foreman.Requests.OpenPrJob.run(request.id)

    assert %{state: "failed", outcome: %{"reason" => "outcome unknown"}} =
             Requests.get(request.id)

    refute_received {:created, _}
    {:ok, snapshot} = Foreman.Forge.Fake.list("owner/repo", server: fake)
    assert length(snapshot["change_requests"]) == 1
    assert Repo.aggregate(from(e in "request_events", where: e.event == "start"), :count) == 1
  end

  for {change, reason} <- [
        {:disabled, "forge_disabled"},
        {:repointed, "config_changed"},
        {:stage, "not_committed"},
        {:readonly, "read_only"}
      ] do
    @change change
    @reason reason
    test "job refuses #{change} after approval", %{facts: facts, fake: fake} do
      committed()
      {:ok, request} = ask(facts)
      Requests.resolve(request.id, :approve, %{})

      case @change do
        :disabled ->
          Repo.delete_all("board_config")

        :repointed ->
          config =
            Foreman.RuntimeState.config().config
            |> put_in(["repos", Access.at(0), "github"], "other/repo")

          Repo.update_all("board_config", set: [config: config])

        :stage ->
          Repo.update_all("tickets", set: [stage: "abandoned"])

        :readonly ->
          Application.put_env(:foreman, :forge_adapter, Foreman.Test.ReadOnlyForge)
      end

      Foreman.Requests.OpenPrJob.run(request.id)
      assert %{state: "failed", outcome: %{"reason" => @reason}} = Requests.get(request.id)
      {:ok, snapshot} = Foreman.Forge.Fake.list("owner/repo", server: fake)
      assert snapshot["change_requests"] == []
    end
  end

  test "configuration removal during the last head read prevents creation", %{facts: facts} do
    committed()
    {:ok, request} = ask(facts)
    Requests.resolve(request.id, :approve, %{})
    Application.put_env(:foreman, :forge_adapter, Foreman.Forge.GitHub)
    Application.put_env(:foreman, :forge_options, token: "test", plug: {Req.Test, __MODULE__})

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/repos/owner/repo/git/ref/heads/main" ->
          Req.Test.json(conn, %{
            "ref" => "refs/heads/main",
            "object" => %{"type" => "commit", "sha" => @sha}
          })

        "/graphql" ->
          Req.Test.json(
            conn,
            File.read!("test/fixtures/forge/form-engine.json") |> Jason.decode!()
          )

        "/repos/owner/repo/git/ref/heads/feature" ->
          Repo.delete_all("board_config")

          Req.Test.json(conn, %{
            "ref" => "refs/heads/feature",
            "object" => %{"type" => "commit", "sha" => @sha}
          })

        _ ->
          send(self(), :created)
          Req.Test.json(conn, %{})
      end
    end)

    Foreman.Requests.OpenPrJob.run(request.id)
    assert %{state: "failed", outcome: %{"reason" => "forge_disabled"}} = Requests.get(request.id)
    refute_received :created
  end

  test "head read outage is not evidence of movement", %{facts: facts} do
    committed()
    {:ok, request} = ask(facts)
    Application.put_env(:foreman, :forge_adapter, Foreman.Forge.GitHub)
    Application.put_env(:foreman, :forge_options, token: "test", plug: {Req.Test, __MODULE__})
    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 503, "Unavailable"))
    Requests.reconcile_open_prs()
    assert Requests.get(request.id).state == "pending"
  end

  test "two approved asks for the same head still create only one PR", %{facts: facts, fake: fake} do
    committed()
    {:ok, first} = ask(facts)
    {:ok, second} = ask(facts)
    Requests.resolve(first.id, :approve, %{})
    Requests.resolve(second.id, :approve, %{})
    Foreman.Requests.OpenPrJob.run(first.id)
    Foreman.Requests.OpenPrJob.run(second.id)
    assert Requests.get(first.id).state == "done"
    assert %{state: "failed", outcome: %{"reason" => "already_open"}} = Requests.get(second.id)
    {:ok, snapshot} = Foreman.Forge.Fake.list("owner/repo", server: fake)
    assert length(snapshot["change_requests"]) == 1
  end

  test "creation requires both write and create-change-request capabilities", %{facts: facts} do
    committed()

    for adapter <- [Foreman.Test.ReadOnlyForge, Foreman.Test.WeakForge] do
      Application.put_env(:foreman, :forge_adapter, adapter)
      assert {:error, :read_only} = ask(facts)
    end
  end

  test "creation refuses uncommitted tickets", %{facts: facts} do
    assert {:error, :not_committed} = ask(facts)
  end

  describe "human merge policy" do
    setup %{fake: fake} do
      config =
        Foreman.RuntimeState.config().config
        |> update_in(
          ["repos", Access.at(0)],
          &Map.merge(&1, %{"merge_policy" => "human", "merge_base" => "staging"})
        )

      Repo.update_all("board_config", set: [config: config])
      # Non-default base: main is the forge default but unused; staging is the PR base.
      Agent.update(fake, &put_in(&1, ["branches", "staging"], String.duplicate("c", 40)))
      {:ok, snapshot} = Foreman.Forge.Fake.list("owner/repo", server: fake)
      Foreman.Forge.Store.replace("sample", "owner/repo", snapshot)
      :ok
    end

    test "open_pr targets the configured base and never the unused default", %{
      facts: facts,
      fake: fake
    } do
      committed()
      assert {:error, :human_merge_base_branch} = ask(facts)
      assert {:ok, request} = ask(Map.put(facts, "base_branch", "staging"))
      Requests.resolve(request.id, :approve, %{})
      assert :ok = Foreman.Requests.OpenPrJob.run(request.id)
      assert %{state: "done"} = Requests.get(request.id)
      {:ok, snapshot} = Foreman.Forge.Fake.list("owner/repo", server: fake)

      assert [%{"target_branch" => "staging", "source_branch" => "feature"}] =
               snapshot["change_requests"]
    end

    test "a project whose code lives in a separate checkout opens PRs against merge_base", %{
      facts: facts,
      fake: fake
    } do
      committed()

      config =
        Foreman.RuntimeState.config().config
        |> update_in(
          ["repos", Access.at(0)],
          &Map.merge(&1, %{"path" => "/tmp/workspace", "code_path" => "/tmp/code"})
        )

      Repo.update_all("board_config", set: [config: config])
      assert {:error, :human_merge_base_branch} = ask(facts)
      assert {:ok, request} = ask(Map.put(facts, "base_branch", "staging"))
      Requests.resolve(request.id, :approve, %{})
      assert :ok = Foreman.Requests.OpenPrJob.run(request.id)
      {:ok, snapshot} = Foreman.Forge.Fake.list("owner/repo", server: fake)
      assert [%{"target_branch" => "staging"}] = snapshot["change_requests"]
    end

    test "a stacked PR may target the head branch of an open PR", %{facts: facts, fake: fake} do
      committed()

      Agent.update(fake, fn snapshot ->
        snapshot
        |> put_in(["branches", "parent"], String.duplicate("d", 40))
        |> Map.put("change_requests", [
          %{
            "number" => 1,
            "source_branch" => "parent",
            "target_branch" => "staging",
            "state" => "open"
          }
        ])
      end)

      {:ok, snapshot} = Foreman.Forge.Fake.list("owner/repo", server: fake)
      Foreman.Forge.Store.replace("sample", "owner/repo", snapshot)
      assert {:ok, _} = ask(Map.put(facts, "base_branch", "parent"))
    end

    test "the job refuses a wrong base forced past creation", %{facts: facts, fake: fake} do
      committed()
      config = Foreman.RuntimeState.config().config
      board = put_in(config, ["repos", Access.at(0), "merge_policy"], "board")
      Repo.update_all("board_config", set: [config: board])
      {:ok, request} = ask(facts)
      Requests.resolve(request.id, :approve, %{})
      Repo.update_all("board_config", set: [config: config])
      assert :ok = Foreman.Requests.OpenPrJob.run(request.id)

      assert %{state: "failed", outcome: %{"reason" => "human_merge_base_branch"}} =
               Requests.get(request.id)

      {:ok, snapshot} = Foreman.Forge.Fake.list("owner/repo", server: fake)
      assert snapshot["change_requests"] == []
    end
  end
end
