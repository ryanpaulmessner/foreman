defmodule Foreman.HumanMergeSyncTest do
  @moduledoc "Forge sync observes a person's merge on GitHub for a human-merge repo."
  use Foreman.DataCase, async: false
  alias Foreman.{Overlay, Forge.SyncJob, Forge.Store}

  @remote "owner/report-scratch"

  setup do
    Repo.insert_all("board_config", [
      %{
        id: 1,
        config: %{
          "repos" => [
            %{
              "key" => "work",
              "forge" => "github",
              "github" => @remote,
              "enabled" => true,
              "merge_policy" => "human",
              "merge_base" => "staging"
            }
          ]
        },
        source: "test",
        discovered: [],
        loaded_at: DateTime.utc_now()
      }
    ])

    Overlay.backfill(
      "work",
      for(
        id <- ~w(work-aaa work-bbb work-ccc work-ddd),
        do: %{bead_id: id, status: "open", issue_type: "task"}
      )
    )

    :ok
  end

  defp sync(fixture) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:forge_request, conn.method, conn.request_path, Jason.decode!(body)["query"]})

      Req.Test.json(
        conn,
        Jason.decode!(File.read!("test/fixtures/forge/human-merge/" <> fixture))
      )
    end)

    Repo.update_all("forge_snapshots",
      set: [attempted_at: DateTime.add(DateTime.utc_now(), -121)]
    )

    SyncJob.sync("work", Foreman.Forge.GitHub, token: "test", plug: {Req.Test, __MODULE__})
  end

  defp stage(id), do: Overlay.get({"work", id}).stage

  test "a person's merge commit and a squash each move only their ticket to merged" do
    sync("open.json")

    assert Enum.map(~w(work-aaa work-bbb work-ccc work-ddd), &stage/1) ==
             List.duplicate(:pr_open, 4)

    assert_received {:forge_request, "POST", "/graphql", _first}
    sync("merged-commit.json")
    assert_received {:forge_request, "POST", "/graphql", query}
    assert query =~ "pr11: pullRequest(number:11)"
    assert stage("work-aaa") == :merged
    assert Enum.map(~w(work-bbb work-ccc work-ddd), &stage/1) == List.duplicate(:pr_open, 3)
    assert Foreman.Drilldown.ticket({"work", "work-aaa"}).close_suggested

    sync("merged-squash.json")
    assert stage("work-ccc") == :merged
    assert Foreman.Drilldown.ticket({"work", "work-ccc"}).close_suggested
    squashed = Enum.find(Store.get("work").snapshot["change_requests"], &(&1["number"] == 13))
    # The squash commit on staging is not the PR head and no merge sha is read or needed.
    assert squashed["state"] == "merged"
    assert Store.get("work").snapshot["branches"]["staging"] != squashed["head_sha"]
    refute Map.has_key?(squashed, "merge_sha")
    assert List.last(Overlay.history({"work", "work-ccc"})).event == "cr_merged"
  end

  test "observing a merge never writes to the forge or retargets the stacked child" do
    sync("open.json")
    sync("merged-commit.json")
    sync("merged-squash.json")

    for _ <- 1..3 do
      assert_received {:forge_request, "POST", "/graphql", query}
      refute query =~ "mutation"
    end

    refute_received {:forge_request, _, _, _}
    assert Repo.aggregate(Foreman.Merge.Record, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0

    child = Enum.find(Store.get("work").snapshot["change_requests"], &(&1["number"] == 12))
    assert %{"state" => "open", "target_branch" => "work/aaa"} = child
  end
end
