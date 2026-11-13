defmodule Foreman.PushTryItTest do
  use Foreman.DataCase, async: false
  alias Foreman.Requests.Push

  setup do
    path = Path.join(System.tmp_dir!(), "push-try-it-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    git = fn args ->
      {out, 0} = System.cmd("git", args, cd: path, stderr_to_stdout: true)
      String.trim(out)
    end

    git.(["init", "-b", "main"])
    git.(["config", "user.name", "Fixture"])
    git.(["config", "user.email", "fixture@example.com"])
    git.(["commit", "--allow-empty", "-m", "initial"])
    git.(["checkout", "-b", "feature"])
    File.mkdir_p!(Path.join(path, "lib/foreman_web"))
    File.write!(Path.join(path, "lib/foreman_web/x.ex"), "UI version one")
    git.(["add", "."])
    git.(["commit", "-m", "UI"])
    sha = git.(["rev-parse", "HEAD"])
    on_exit(fn -> File.rm_rf!(path) end)

    repo = %{
      "key" => "sample",
      "path" => path,
      "forge" => "github",
      "github" => "owner/repo",
      "enabled" => true,
      "try_it" => %{"paths" => ["lib/foreman_web/**", "assets/**"]}
    }

    Repo.insert_all("board_config", [
      %{
        id: 1,
        config: %{"repos" => [repo]},
        source: "test",
        discovered: [],
        loaded_at: DateTime.utc_now()
      }
    ])

    Foreman.Forge.Store.replace("sample", "owner/repo", %{
      "default_branch" => "main",
      "change_requests" => []
    })

    row = %{repo_key: "sample", bead_id: "s-1", stage: :committed, machine: Foreman.Ticket}

    facts = %{
      "worktree" => path,
      "local_branch" => "feature",
      "remote_branch" => "feature",
      "expected_sha" => sha
    }

    %{path: path, git: git, sha: sha, row: row, facts: facts}
  end

  defp review(sha, attrs \\ %{}) do
    Foreman.Repo.insert!(
      struct!(
        Foreman.Requests.Request,
        Map.merge(
          %{
            actor: "pi",
            repo_key: "sample",
            bead_id: "s-other",
            kind: "review_ui",
            state: "answered",
            facts: %{"url" => "http://localhost:4000", "sha" => sha},
            outcome: %{"answer" => "Works"}
          },
          attrs
        )
      )
    )
  end

  test "Works at T on this ticket covers T", %{sha: sha, facts: facts, row: row} do
    review(sha, %{bead_id: "s-1"})
    assert {:ok, _} = Push.validate(facts, row)
  end

  test "configured merge_base takes precedence over forge default", %{
    sha: sha,
    git: git,
    path: path,
    facts: facts,
    row: row
  } do
    git.(["branch", "staging", sha])
    config = Foreman.RuntimeState.config().config
    config = put_in(config, ["repos", Access.at(0), "merge_base"], "staging")
    Repo.update_all("board_config", set: [config: config])
    File.write!(Path.join(path, "backend.ex"), "backend")
    git.(["add", "."])
    git.(["commit", "-m", "backend"])

    assert {:ok, _} =
             Push.validate(Map.put(facts, "expected_sha", git.(["rev-parse", "HEAD"])), row)
  end

  test "gate reads commits in a linked worktree", %{
    sha: sha,
    git: git,
    path: path,
    facts: facts,
    row: row
  } do
    linked = path <> "-linked"
    git.(["worktree", "add", "-b", "linked", linked, sha])
    on_exit(fn -> File.rm_rf!(linked) end)
    facts = Map.merge(facts, %{"worktree" => linked, "local_branch" => "linked"})
    assert {:error, %{error: "try_it_missing"}} = Push.validate(facts, row)
    review(sha)
    assert {:ok, _} = Push.validate(facts, row)
  end

  test "unsafe git configuration is refused before running a diff", %{
    git: git,
    facts: facts,
    row: row
  } do
    git.(["config", "diff.external", "false"])
    assert {:error, :unsafe_git_config} = Push.validate(facts, row)
  end

  test "unavailable git objects fail closed", %{facts: facts, row: row} do
    Foreman.Forge.Store.replace("sample", "owner/repo", %{
      "default_branch" => "main",
      "branches" => %{"main" => String.duplicate("a", 40)},
      "change_requests" => []
    })

    assert {:error, :try_it_diff_failed} = Push.validate(facts, row)
  end

  test "exception does not bypass human merge policy", %{facts: facts, row: row} do
    config = Foreman.RuntimeState.config().config
    config = put_in(config, ["repos", Access.at(0), "merge_policy"], "human")
    Repo.update_all("board_config", set: [config: config])
    facts = Map.merge(facts, %{"remote_branch" => "main", "no_try_it" => "Emergency"})
    assert {:error, :human_merge_base_branch} = Push.validate(facts, row)
  end

  test "Works at T on another ticket in the same repo covers T", %{
    sha: sha,
    facts: facts,
    row: row
  } do
    review(sha)
    assert {:ok, _} = Push.validate(facts, row)
  end

  for operation <- ["merge", "rebase"] do
    test "Works survives a non-UI #{operation}", %{
      sha: sha,
      git: git,
      path: path,
      facts: facts,
      row: row
    } do
      review(sha)
      git.(["checkout", "main"])
      File.write!(Path.join(path, "backend.ex"), "backend")
      git.(["add", "."])
      git.(["commit", "-m", "backend"])
      git.(["checkout", "feature"])
      git.([unquote(operation), "main"])
      pushed = git.(["rev-parse", "HEAD"])
      refute pushed == sha
      assert {:ok, _} = Push.validate(Map.put(facts, "expected_sha", pushed), row)
    end
  end

  test "UI edits after Works require another try", %{
    sha: sha,
    git: git,
    path: path,
    facts: facts,
    row: row
  } do
    review(sha)
    File.write!(Path.join(path, "lib/foreman_web/x.ex"), "UI version two")
    git.(["commit", "-am", "UI edit"])

    assert {:error, %{error: "try_it_missing"}} =
             Push.validate(Map.put(facts, "expected_sha", git.(["rev-parse", "HEAD"])), row)
  end

  for attrs <- [
        %{outcome: %{"answer" => "Change it"}},
        %{outcome: %{"answer" => "Found a problem"}},
        %{repo_key: "elsewhere"},
        %{state: "pending"}
      ] do
    test "a review with #{inspect(attrs)} cannot cover a push", %{
      sha: sha,
      facts: facts,
      row: row
    } do
      review(sha, unquote(Macro.escape(attrs)))
      assert {:error, %{error: "try_it_missing"}} = Push.validate(facts, row)
    end
  end

  test "a review without a URL cannot cover a push", %{sha: sha, facts: facts, row: row} do
    review(sha, %{facts: %{"sha" => sha}})
    assert {:error, %{error: "try_it_missing"}} = Push.validate(facts, row)
  end

  test "a repo without try_it keeps accepting pushes", %{facts: facts, row: row} do
    config = Foreman.RuntimeState.config().config
    config = update_in(config, ["repos", Access.at(0)], &Map.delete(&1, "try_it"))
    Repo.update_all("board_config", set: [config: config])
    assert {:ok, _} = Push.validate(facts, row)
  end

  test "stacked child with only non-UI changes uses the recorded blocker's open PR", %{
    sha: sha,
    git: git,
    path: path,
    facts: facts,
    row: row
  } do
    git.(["branch", "parent", sha])

    Repo.insert_all("bead_repos", [
      %{key: "sample", export_sha256: "test", synced_at: DateTime.utc_now()}
    ])

    Repo.insert_all("beads", [
      %{
        repo_key: "sample",
        bead_id: "s-1",
        raw: %{"dependencies" => [%{"type" => "blocks", "depends_on_id" => "s-parent"}]}
      }
    ])

    Foreman.Forge.Store.replace("sample", "owner/repo", %{
      "default_branch" => "main",
      "change_requests" => [
        %{
          "state" => "open",
          "source_branch" => "parent",
          "title" => "s-parent: parent",
          "body" => "",
          "head_sha" => sha
        }
      ]
    })

    File.write!(Path.join(path, "backend.ex"), "backend")
    git.(["add", "."])
    git.(["commit", "-m", "child"])

    assert {:ok, _} =
             Push.validate(Map.put(facts, "expected_sha", git.(["rev-parse", "HEAD"])), row)
  end

  test "exception reason is retained for the approval card", %{facts: facts, row: row} do
    assert {:ok, accepted} = Push.validate(Map.put(facts, "no_try_it", "CSS-only emergency"), row)
    assert accepted["no_try_it"] == "CSS-only emergency"
  end

  test "empty exception reasons are refused", %{facts: facts, row: row} do
    for reason <- ["", "  ", false, 42] do
      assert {:error, :invalid_facts} = Push.validate(Map.put(facts, "no_try_it", reason), row)
    end
  end

  test "untried UI changes are refused with paths and the next command", %{facts: facts, row: row} do
    assert {:error, %{error: "try_it_missing", message: message}} = Push.validate(facts, row)

    assert message ==
             "s-1 changes 1 UI files (lib/foreman_web/x.ex). Post a review_ui card with --url, --walkthrough and --sha, or pass --no-try-it \"<reason>\"."
  end
end
