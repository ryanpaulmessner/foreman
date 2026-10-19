defmodule Foreman.PushTest do
  use Foreman.DataCase, async: false
  alias Foreman.{Overlay, Requests}

  setup do
    path = Path.join(System.tmp_dir!(), "foreman-push-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    git = fn args ->
      {out, 0} = System.cmd("git", args, cd: path, stderr_to_stdout: true)
      String.trim(out)
    end

    git.(["init", "-b", "main"])

    git.([
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.com",
      "commit",
      "--allow-empty",
      "-m",
      "initial"
    ])

    sha = git.(["rev-parse", "HEAD"])
    on_exit(fn -> File.rm_rf!(path) end)

    Repo.insert_all("board_config", [
      %{
        id: 1,
        config: %{
          "repos" => [
            %{
              "key" => "sample",
              "path" => path,
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

    Foreman.Forge.Store.replace("sample", "owner/repo", %{
      "default_branch" => "main",
      "change_requests" => []
    })

    facts = %{
      "worktree" => path,
      "local_branch" => "main",
      "expected_sha" => sha,
      "remote_branch" => "feature"
    }

    %{path: path, sha: sha, facts: facts, git: git}
  end

  defp committed do
    Repo.update_all("tickets", set: [stage: "committed"])
  end

  test "creation binds a committed ask to the configured remote", %{facts: facts} do
    committed()
    assert {:ok, request} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
    assert request.facts["remote"] == "owner/repo"
    assert request.facts["expected_sha"] == facts["expected_sha"]
  end

  test "creation refuses a foreign worktree", %{facts: facts} do
    committed()

    foreign =
      Path.join(System.tmp_dir!(), "foreman-foreign-#{System.unique_integer([:positive])}")

    File.mkdir_p!(foreign)
    System.cmd("git", ["init", "-b", "main", foreign], stderr_to_stdout: true)
    on_exit(fn -> File.rm_rf!(foreign) end)

    assert {:error, :foreign_worktree} =
             Requests.ask({"sample", "s-1"}, "push", %{
               "facts" => Map.put(facts, "worktree", foreign)
             })
  end

  test "creation refuses forge none", %{facts: facts} do
    committed()
    config = Foreman.RuntimeState.config().config
    config = put_in(config, ["repos", Access.at(0), "forge"], "none")
    Repo.update_all("board_config", set: [config: config])

    assert {:error, :forge_disabled} =
             Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
  end

  test "default branch is allowed for one-off tickets but refused inside an epic", %{facts: facts} do
    committed()
    facts = Map.put(facts, "remote_branch", "main")
    assert {:ok, _} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
    Overlay.backfill("sample", [%{bead_id: "s-e", status: "open", issue_type: "epic"}])

    Repo.insert_all("epic_links", [
      %{repo_key: "sample", bead_id: "s-1", epic_repo_key: "sample", epic_bead_id: "s-e"}
    ])

    assert {:error, :epic_default_branch} =
             Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
  end

  test "creation refuses moved sha and invalid refspecs", %{facts: facts} do
    committed()

    for {field, value, reason} <- [
          {"expected_sha", String.duplicate("a", 40), :local_sha_changed},
          {"remote_branch", "+main", :invalid_facts},
          {"local_branch", "../main", :invalid_facts}
        ] do
      assert {:error, ^reason} =
               Requests.ask({"sample", "s-1"}, "push", %{"facts" => Map.put(facts, field, value)})
    end
  end

  test "local branch movement supersedes before approval", %{facts: facts, git: git} do
    committed()
    {:ok, request} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})

    git.([
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.com",
      "commit",
      "--allow-empty",
      "-m",
      "moved"
    ])

    assert {:ok, %{state: "superseded"}} = Requests.resolve(request.id, :approve, %{})
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "preview refuses an approved push and audits the refusal without git", %{facts: facts} do
    committed()
    {:ok, request} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
    {:ok, _} = Requests.resolve(request.id, :approve, %{})
    previous = System.get_env("PREVIEW")
    System.put_env("PREVIEW", "1")

    on_exit(fn ->
      if previous, do: System.put_env("PREVIEW", previous), else: System.delete_env("PREVIEW")
    end)

    fake =
      start_supervised!(
        {Foreman.Forge.Fake, %{"default_branch" => "main", "change_requests" => []}}
      )

    assert :ok =
             Foreman.Requests.PushJob.run(request.id,
               adapter: Foreman.Forge.Fake,
               forge_options: [server: fake],
               command: fn _, _ ->
                 send(self(), :unexpected_git)
                 {"", 0}
               end
             )

    assert %{state: "failed", outcome: %{"reason" => "refused in preview"}} =
             Requests.get(request.id)

    refute_received :unexpected_git

    assert Repo.exists?(
             from e in "request_events",
               where:
                 e.request_id == ^Ecto.UUID.dump!(request.id) and e.event == "failed" and
                   fragment("?->>'reason'", e.payload) == "refused in preview"
           )
  end

  test "preview perform refuses even without a credential service", %{facts: facts} do
    committed()
    {:ok, request} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
    {:ok, _} = Requests.resolve(request.id, :approve, %{})
    previous = System.get_env("PREVIEW")
    System.put_env("PREVIEW", "1")

    on_exit(fn ->
      if previous, do: System.put_env("PREVIEW", previous), else: System.delete_env("PREVIEW")
    end)

    assert :ok = Foreman.Requests.PushJob.perform(%Oban.Job{args: %{"request_id" => request.id}})

    assert %{state: "failed", outcome: %{"reason" => "refused in preview"}} =
             Requests.get(request.id)
  end

  test "worker pushes the exact sha to a bare remote only once", %{facts: facts, path: path} do
    committed()
    bare = path <> "-bare"
    System.cmd("git", ["clone", "--bare", path, bare], stderr_to_stdout: true)
    on_exit(fn -> File.rm_rf!(bare) end)
    {:ok, request} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
    assert {:ok, %{state: "approved"}} = Requests.resolve(request.id, :approve, %{})

    fake =
      start_supervised!(
        {Foreman.Forge.Fake, %{"default_branch" => "main", "change_requests" => []}}
      )

    opts = [
      adapter: Foreman.Forge.Fake,
      forge_options: [server: fake],
      command: fn args, options ->
        send(self(), :push_attempt)

        System.cmd(
          "git",
          Enum.map(args, fn
            "https://github.com/owner/repo.git" -> bare
            arg -> arg
          end),
          options
        )
      end
    ]

    assert :ok = Foreman.Requests.PushJob.run(request.id, opts)
    assert %{state: "done"} = Requests.get(request.id)
    assert {sha, 0} = System.cmd("git", ["--git-dir", bare, "rev-parse", "refs/heads/feature"])
    assert String.trim(sha) == facts["expected_sha"]
    assert_receive :push_attempt
    assert :ok = Foreman.Requests.PushJob.run(request.id, opts)
    refute_receive :push_attempt
  end

  defp job_options(path) do
    bare = path <> "-bare"
    {_, 0} = System.cmd("git", ["clone", "--bare", path, bare], stderr_to_stdout: true)
    on_exit(fn -> File.rm_rf!(bare) end)

    fake =
      start_supervised!(
        {Foreman.Forge.Fake, %{"default_branch" => "main", "change_requests" => []}}
      )

    [
      adapter: Foreman.Forge.Fake,
      forge_options: [server: fake],
      command: fn args, options ->
        send(self(), :push_attempt)

        System.cmd(
          "git",
          Enum.map(args, fn
            "https://github.com/owner/repo.git" -> bare
            arg -> arg
          end),
          options
        )
      end
    ]
  end

  test "job rechecks moved sha and never invokes push", %{facts: facts, path: path, git: git} do
    committed()
    opts = job_options(path)
    {:ok, request} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
    Requests.resolve(request.id, :approve, %{})

    git.([
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.com",
      "commit",
      "--allow-empty",
      "-m",
      "moved"
    ])

    assert :ok = Foreman.Requests.PushJob.run(request.id, opts)

    assert %{state: "failed", outcome: %{"reason" => "local_sha_changed"}} =
             Requests.get(request.id)

    refute_receive :push_attempt
  end

  test "job refuses default branch even if epic membership changes after creation", %{
    facts: facts,
    path: path
  } do
    committed()
    opts = job_options(path)

    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "push", %{
        "facts" => Map.put(facts, "remote_branch", "main")
      })

    Requests.resolve(request.id, :approve, %{})
    Overlay.backfill("sample", [%{bead_id: "s-e", status: "open", issue_type: "epic"}])

    Repo.insert_all("epic_links", [
      %{repo_key: "sample", bead_id: "s-1", epic_repo_key: "sample", epic_bead_id: "s-e"}
    ])

    assert :ok = Foreman.Requests.PushJob.run(request.id, opts)

    assert %{state: "failed", outcome: %{"reason" => "epic_default_branch"}} =
             Requests.get(request.id)

    refute_receive :push_attempt
  end

  test "non-fast-forward push cannot overwrite the bare remote", %{
    facts: facts,
    path: path,
    git: git
  } do
    committed()
    opts = job_options(path)

    git.([
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.com",
      "commit",
      "--amend",
      "--allow-empty",
      "-m",
      "diverged"
    ])

    local = git.(["rev-parse", "HEAD"])
    facts = facts |> Map.put("expected_sha", local) |> Map.put("remote_branch", "main")
    {:ok, request} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
    Requests.resolve(request.id, :approve, %{})
    assert :ok = Foreman.Requests.PushJob.run(request.id, opts)

    assert %{state: "failed", outcome: %{"reason" => "not a fast-forward"}} =
             Requests.get(request.id)

    assert {remote, 0} = System.cmd("git", ["--git-dir", path <> "-bare", "rev-parse", "main"])
    refute String.trim(remote) == local
  end

  test "rescuing an interrupted attempt fails unknown without a second push", %{
    facts: facts,
    path: path
  } do
    committed()
    opts = job_options(path)
    {:ok, request} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
    Requests.resolve(request.id, :approve, %{})
    Requests.resolve(request.id, :start, %{})
    assert :ok = Foreman.Requests.PushJob.run(request.id, opts)

    assert %{state: "failed", outcome: %{"reason" => "outcome unknown"}} =
             Requests.get(request.id)

    refute_receive :push_attempt
  end

  test "pending observation supersedes a moved branch", %{facts: facts, git: git} do
    committed()
    {:ok, request} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})

    git.([
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.com",
      "commit",
      "--allow-empty",
      "-m",
      "moved"
    ])

    Requests.reconcile_pushes()
    assert Requests.get(request.id).state == "superseded"
  end

  test "expired executing attempts reconcile unknown even with a pruned job", %{facts: facts} do
    committed()
    {:ok, request} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
    Requests.resolve(request.id, :approve, %{})
    Requests.resolve(request.id, :start, %{})
    Repo.delete_all(Oban.Job)
    Requests.reconcile_pushes()

    assert %{state: "failed", outcome: %{"reason" => "outcome unknown"}} =
             Requests.get(request.id)
  end

  test "CLI names every push fact" do
    assert {:ok, %{request: request}} =
             Foreman.CLI.parse([
               "ask",
               "push",
               "s-1",
               "--project",
               "sample",
               "--worktree",
               "/tmp/repo",
               "--branch",
               "feature",
               "--sha",
               String.duplicate("a", 40),
               "--remote-branch",
               "published"
             ])

    assert request["facts"] == %{
             "worktree" => "/tmp/repo",
             "local_branch" => "feature",
             "expected_sha" => String.duplicate("a", 40),
             "remote_branch" => "published"
           }
  end

  test "job refuses config that could redirect credentials or execute helpers", %{
    facts: facts,
    path: path,
    git: git
  } do
    committed()
    opts = job_options(path)
    {:ok, request} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
    Requests.resolve(request.id, :approve, %{})
    git.(["config", "url.https://example.invalid/.insteadOf", "https://github.com/"])
    Foreman.Requests.PushJob.run(request.id, opts)

    assert %{state: "failed", outcome: %{"reason" => "unsafe_git_config"}} =
             Requests.get(request.id)

    refute_receive :push_attempt
  end

  test "one-off default push advances a bare remote fast-forward", %{
    facts: facts,
    path: path,
    git: git
  } do
    committed()
    opts = job_options(path)

    git.([
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.com",
      "commit",
      "--allow-empty",
      "-m",
      "forward"
    ])

    sha = git.(["rev-parse", "HEAD"])
    facts = facts |> Map.put("expected_sha", sha) |> Map.put("remote_branch", "main")
    {:ok, request} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
    Requests.resolve(request.id, :approve, %{})
    Foreman.Requests.PushJob.run(request.id, opts)
    assert %{state: "done"} = Requests.get(request.id)
    assert {remote, 0} = System.cmd("git", ["--git-dir", path <> "-bare", "rev-parse", "main"])
    assert String.trim(remote) == sha
  end

  test "linked worktrees and packed local refs retain repository identity", %{
    facts: facts,
    path: path,
    git: git
  } do
    committed()
    worktree = path <> "-linked"
    git.(["worktree", "add", "-b", "linked", worktree])
    on_exit(fn -> File.rm_rf!(worktree) end)
    git.(["pack-refs", "--all"])
    facts = facts |> Map.put("worktree", worktree) |> Map.put("local_branch", "linked")
    assert {:ok, _} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
  end

  test "killing a job after its external write cannot send the write twice", %{
    facts: facts,
    path: path
  } do
    committed()
    opts = job_options(path)
    {:ok, request} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
    Requests.resolve(request.id, :approve, %{})
    parent = self()
    original = opts[:command]

    command = fn args, options ->
      result = original.(args, options)
      send(parent, {:pushed, self(), result})

      receive do
        :release -> result
      end
    end

    supervisor = start_supervised!({Task.Supervisor, []})

    {:ok, pid} =
      Task.Supervisor.start_child(supervisor, fn ->
        receive do
          :start -> Foreman.Requests.PushJob.run(request.id, Keyword.put(opts, :command, command))
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    ref = Process.monitor(pid)
    send(pid, :start)
    assert_receive {:pushed, ^pid, {_, 0}}, 5_000
    assert Requests.get(request.id).state == "executing"
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    Foreman.Requests.PushJob.run(request.id, opts)

    assert %{state: "failed", outcome: %{"reason" => "outcome unknown"}} =
             Requests.get(request.id)

    refute_receive :push_attempt
    assert {remote, 0} = System.cmd("git", ["--git-dir", path <> "-bare", "rev-parse", "feature"])
    assert String.trim(remote) == facts["expected_sha"]
    assert Repo.aggregate(from(e in "request_events", where: e.event == "start"), :count) == 1
  end

  test "approval note survives worker transitions", %{facts: facts, path: path} do
    committed()
    opts = job_options(path)
    {:ok, request} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
    Requests.resolve(request.id, :approve, %{"note" => "Publish this SHA"})
    Foreman.Requests.PushJob.run(request.id, opts)
    assert %{state: "done", note: "Publish this SHA"} = Requests.get(request.id)
  end

  test "read-only forge adapter cannot authorize a local push", %{facts: facts, path: path} do
    committed()
    opts = job_options(path) |> Keyword.put(:adapter, Foreman.Test.ReadOnlyForge)
    {:ok, request} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
    Requests.resolve(request.id, :approve, %{})
    Foreman.Requests.PushJob.run(request.id, opts)
    assert %{state: "failed", outcome: %{"reason" => "read_only"}} = Requests.get(request.id)
    refute_receive :push_attempt
  end

  test "configuration removal during the forge read prevents the push", %{
    facts: facts,
    path: path
  } do
    committed()

    opts =
      job_options(path)
      |> Keyword.put(:adapter, Foreman.Forge.GitHub)
      |> Keyword.put(:forge_options, token: "test", plug: {Req.Test, __MODULE__})

    Req.Test.stub(__MODULE__, fn conn ->
      Repo.delete_all("board_config")
      Req.Test.json(conn, File.read!("test/fixtures/forge/form-engine.json") |> Jason.decode!())
    end)

    {:ok, request} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
    Requests.resolve(request.id, :approve, %{})
    Foreman.Requests.PushJob.run(request.id, opts)
    assert %{state: "failed", outcome: %{"reason" => "forge_disabled"}} = Requests.get(request.id)
    refute_receive :push_attempt
  end

  test "credentials stay out of argv and audit even when git returns them", %{
    facts: facts,
    path: path
  } do
    committed()
    opts = job_options(path)
    token = "test-memory-only"
    opts = Keyword.update!(opts, :forge_options, &Keyword.put(&1, :token, token))

    opts =
      Keyword.put(opts, :command, fn args, options ->
        send(self(), {:push_command, args, options})
        {"remote failed " <> token, 1}
      end)

    {:ok, request} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
    Requests.resolve(request.id, :approve, %{})
    Foreman.Requests.PushJob.run(request.id, opts)

    assert %{state: "failed", outcome: %{"reason" => "outcome unknown"}} =
             Requests.get(request.id)

    assert_receive {:push_command, args, options}
    refute Enum.any?(args, &String.contains?(&1, token))
    assert "credential.helper=!gh auth git-credential" in args
    assert "credential.helper=" in args
    assert "https://github.com/owner/repo.git" in args
    refute Enum.any?(args, &String.starts_with?(&1, "--force"))
    assert List.last(args) == facts["expected_sha"] <> ":refs/heads/feature"
    assert List.keyfind(options[:env], "GH_TOKEN", 0) == {"GH_TOKEN", token}
    audit = Repo.query!("SELECT payload FROM request_events")
    refute inspect(audit.rows) =~ token
  end

  test "creation refuses a ticket that is not committed", %{facts: facts} do
    assert {:error, :not_committed} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
  end

  describe "human merge policy" do
    defp human!(extra \\ %{}) do
      config = Foreman.RuntimeState.config().config

      config =
        update_in(
          config,
          ["repos", Access.at(0)],
          &Map.merge(
            &1,
            Map.merge(%{"merge_policy" => "human", "merge_base" => "staging"}, extra)
          )
        )

      Repo.update_all("board_config", set: [config: config])
    end

    test "push to the base or the default branch is refused at creation, one-off ticket included",
         %{facts: facts} do
      committed()
      human!()
      # s-1 has no epic: the default-branch exception for one-offs does not apply.
      for branch <- ["staging", "main"] do
        assert {:error, :human_merge_base_branch} =
                 Requests.ask({"sample", "s-1"}, "push", %{
                   "facts" => Map.put(facts, "remote_branch", branch)
                 })
      end

      assert {:ok, request} = Requests.ask({"sample", "s-1"}, "push", %{"facts" => facts})
      assert request.facts["remote_branch"] == "feature"
    end

    test "a machine-wide default without merge_base still protects the default branch", %{
      facts: facts
    } do
      committed()
      config = Foreman.RuntimeState.config().config |> Map.put("merge_policy", "human")
      Repo.update_all("board_config", set: [config: config])

      assert {:error, :human_merge_base_branch} =
               Requests.ask({"sample", "s-1"}, "push", %{
                 "facts" => Map.put(facts, "remote_branch", "main")
               })
    end

    test "the job refuses a base-branch push forced past creation", %{facts: facts, path: path} do
      committed()
      opts = job_options(path)

      for branch <- ["main", "staging"] do
        {:ok, request} =
          Requests.ask({"sample", "s-1"}, "push", %{
            "facts" => Map.put(facts, "remote_branch", branch)
          })

        Requests.resolve(request.id, :approve, %{})
        human!()
        assert :ok = Foreman.Requests.PushJob.run(request.id, opts)

        assert %{state: "failed", outcome: %{"reason" => "human_merge_base_branch"}} =
                 Requests.get(request.id)

        refute_receive :push_attempt
        human!(%{"merge_policy" => "board"})
      end
    end
  end
end
