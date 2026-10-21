defmodule Foreman.Week.PrLinksTest do
  use Foreman.DataCase, async: false
  alias Foreman.Week.PrLinks

  test "scheduled dispatch queues only week repositories and suppresses duplicate work" do
    Foreman.Repo.insert_all("board_config", [
      %{
        id: 1,
        config: %{"repos" => []},
        source: "test",
        discovered: [],
        loaded_at: DateTime.utc_now()
      }
    ])

    assert :ok = Foreman.Week.HistoryJob.perform(%Oban.Job{args: %{}})
    assert :ok = Foreman.Week.HistoryJob.perform(%Oban.Job{args: %{}})
    jobs = Foreman.Repo.all(Oban.Job)
    assert [%Oban.Job{args: %{"key" => "work"}, worker: "Foreman.Week.HistoryJob"}] = jobs
    assert :ok = Foreman.Week.HistoryJob.perform(hd(jobs))
  end

  test "backfill is once only, later reads use 21 days, and failed fetch keeps cache" do
    Foreman.Beads.Projection.replace(
      "work",
      Jason.encode!(%{
        id: "rs-one",
        title: "One",
        issue_type: "task",
        status: "open",
        dependencies: []
      })
    )

    pr = %{
      "number" => 12,
      "title" => "rs-one",
      "body" => "",
      "source_branch" => "rs-one",
      "target_branch" => "staging",
      "head_sha" => String.duplicate("a", 40),
      "state" => "merged",
      "url" => "https://github.com/org/repo/pull/12"
    }

    reader = fn _remote, days, _opts ->
      send(self(), {:days, days})
      {:ok, [pr]}
    end

    path = Path.join(System.tmp_dir!(), "week-no-remote-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    for days <- [60, 21] do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Foreman.Week.HistoryJob.refresh("work", "org/repo", path, reader, [])
        end)

      assert_receive {:days, ^days}
      assert length(Regex.scan(~r/Week containment fetch failed/, log)) == 1
      assert [%{number: 12}] = PrLinks.list("work", "org/repo")

      Foreman.Repo.update_all("week_pr_links",
        set: [in_production: true, in_staging: true, checked_at: DateTime.utc_now()]
      )
    end

    assert [%{in_production: true, in_staging: true}] = PrLinks.list("work", "org/repo")
  end

  test "failed backfill retries 60 days rather than marking incomplete history complete" do
    path =
      Path.join(System.tmp_dir!(), "week-failed-history-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    for _ <- 1..2 do
      ExUnit.CaptureLog.capture_log(fn ->
        Foreman.Week.HistoryJob.refresh(
          "work",
          "org/repo",
          path,
          fn _, days, _ ->
            send(self(), {:days, days})
            {:error, :incomplete}
          end,
          []
        )
      end)

      assert_receive {:days, 60}
    end
  end

  test "changed heads invalidate ancestry without losing first-seen history" do
    Foreman.Beads.Projection.replace(
      "work",
      Jason.encode!(%{
        id: "rs-one",
        title: "One",
        issue_type: "task",
        status: "open",
        dependencies: []
      })
    )

    pr = %{
      "number" => 12,
      "title" => "rs-one",
      "body" => "",
      "source_branch" => "rs-one",
      "target_branch" => "staging",
      "head_sha" => String.duplicate("a", 40),
      "state" => "open",
      "url" => "https://github.com/org/repo/pull/12"
    }

    PrLinks.record("work", "org/repo", [pr])
    [original] = PrLinks.list("work", "org/repo")

    Foreman.Repo.update_all("week_pr_links",
      set: [in_production: true, in_staging: true, checked_at: DateTime.utc_now()]
    )

    PrLinks.record("work", "org/repo", [Map.put(pr, "head_sha", String.duplicate("b", 40))])

    assert [%{in_production: nil, in_staging: nil, checked_at: nil} = updated] =
             PrLinks.list("work", "org/repo")

    assert updated.first_seen_at == original.first_seen_at
    assert updated.head_sha == String.duplicate("b", 40)
  end

  test "worker fetches only tracking refs and page reads cached shipped and staging facts" do
    path = Path.join(System.tmp_dir!(), "week-history-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    git = fn args ->
      {out, 0} = System.cmd("git", args, cd: path, stderr_to_stdout: true)
      String.trim(out)
    end

    git.(["init", "-b", "production"])
    git.(["config", "user.email", "test@example.com"])
    git.(["config", "user.name", "Test"])
    git.(["commit", "--allow-empty", "-m", "initial"])
    git.(["checkout", "-b", "feature"])
    git.(["commit", "--allow-empty", "-m", "feature"])
    shipped = git.(["rev-parse", "HEAD"])
    git.(["checkout", "production"])
    git.(["merge", "--no-ff", "feature", "-m", "deploy"])
    git.(["checkout", "-b", "staging"])
    git.(["checkout", "-b", "second"])
    git.(["commit", "--allow-empty", "-m", "second"])
    staging = git.(["rev-parse", "HEAD"])
    git.(["checkout", "staging"])
    git.(["merge", "--no-ff", "second", "-m", "stage"])
    git.(["remote", "add", "origin", path])
    before_refs = git.(["show-ref", "--heads"])
    before_tree = git.(["status", "--porcelain"])
    today = DateTime.utc_now() |> DateTime.shift_zone!("America/Chicago") |> DateTime.to_date()

    rows =
      for id <- ["rs-one", "rs-two"],
          do: %{
            id: id,
            title: id,
            issue_type: "task",
            status: "closed",
            notes: "- #{today}: worked",
            dependencies: []
          }

    Foreman.Beads.Projection.replace("work", Enum.map_join(rows, "\n", &Jason.encode!/1))

    Foreman.Repo.insert_all("board_config", [
      %{
        id: 1,
        config: %{
          "repos" => [
            %{
              "key" => "work",
              "enabled" => true,
              "forge" => "github",
              "github" => "org/repo",
              "code_path" => path
            }
          ]
        },
        source: "test",
        discovered: [],
        loaded_at: DateTime.utc_now()
      }
    ])

    prs =
      for {id, n, sha} <- [{"rs-one", 1, shipped}, {"rs-two", 2, staging}],
          do: %{
            "number" => n,
            "title" => id,
            "body" => "",
            "source_branch" => id,
            "target_branch" => "staging",
            "head_sha" => sha,
            "state" => "merged",
            "url" => "https://github.com/org/repo/pull/#{n}"
          }

    assert :ok =
             Foreman.Week.HistoryJob.refresh(
               "work",
               "org/repo",
               path,
               fn _, _, _ -> {:ok, prs} end,
               []
             )

    assert git.(["show-ref", "--heads"]) == before_refs
    assert git.(["status", "--porcelain"]) == before_tree
    git.(["merge-base", "--is-ancestor", shipped, "origin/production"])

    assert {_, 1} =
             System.cmd("git", ["merge-base", "--is-ancestor", staging, "origin/production"],
               cd: path
             )

    # Removing the repo proves the page cannot depend on git at read time.
    File.rm_rf!(path)
    model = Foreman.Week.snapshot()

    stages =
      for section <- model.sections,
          group <- section.groups,
          item <- group.items,
          into: %{},
          do: {item.id, item.plain_stage}

    assert stages == %{"rs-one" => "Shipped", "rs-two" => "On staging"}
    assert Foreman.Week.snapshot() == model
  end

  test "forge publication preserves linked merged history across snapshots" do
    Foreman.Beads.Projection.replace(
      "work",
      Jason.encode!(%{
        id: "rs-one",
        title: "One",
        issue_type: "task",
        status: "open",
        dependencies: []
      })
    )

    pr = %{
      "number" => 12,
      "title" => "rs-one",
      "body" => "",
      "source_branch" => "rs-one",
      "target_branch" => "staging",
      "head_sha" => String.duplicate("a", 40),
      "state" => "merged",
      "url" => "https://github.com/org/repo/pull/12"
    }

    Foreman.Forge.Store.replace("work", "org/repo", %{"change_requests" => [pr]})

    assert [%{ticket_id: "rs-one", state: "merged", number: 12}] =
             PrLinks.list("work", "org/repo")

    Foreman.Forge.Store.replace("work", "org/repo", %{"change_requests" => []})
    assert [%{number: 12}] = PrLinks.list("work", "org/repo")
    assert [] = PrLinks.list("work", "other/repo")
  end
end
