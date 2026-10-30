defmodule Foreman.WaitingWithoutCardTest do
  use Foreman.DataCase, async: false
  alias Foreman.{Overlay, Requests, WaitingWithoutCard}

  setup do
    Repo.insert_all("board_config", [
      %{
        id: 1,
        config: %{
          "repos" => [
            %{
              "key" => "sample",
              "enabled" => true,
              "forge" => "github",
              "github" => "owner/repo",
              "merge_policy" => "human"
            }
          ]
        },
        source: "test",
        discovered: [],
        loaded_at: DateTime.utc_now()
      }
    ])

    tickets =
      for {id, type} <- [
            {"s-1", "task"},
            {"s-2", "task"},
            {"s-3", "task"},
            {"s-4", "task"},
            {"s-5", "decision"},
            {"s-6", "task"}
          ] do
        %{
          id: id,
          title: "Title " <> id,
          issue_type: type,
          status: "open",
          dependencies:
            if(id in ["s-4", "s-6"], do: [%{depends_on_id: "s-5", type: "blocks"}], else: [])
        }
      end

    Foreman.Beads.Projection.replace("sample", Enum.map_join(tickets, "\n", &Jason.encode!/1))
    Overlay.apply_event({"sample", "s-1"}, {:commit, %{sha: "abc"}}, %{actor: "claude"})
    Overlay.apply_event({"sample", "s-3"}, {:dispatch, %{window: "build", branch: "feature"}})
    Overlay.apply_event({"sample", "s-3"}, {:report, %{path: "/tmp/report.md"}})

    Foreman.Forge.Store.replace("sample", "owner/repo", %{
      "change_requests" => [
        %{
          "number" => 12,
          "state" => "open",
          "title" => "s-2 Change",
          "body" => "s-2",
          "source_branch" => "s-2",
          "url" => "https://github.com/owner/repo/pull/12"
        }
      ]
    })

    :ok
  end

  test "all four sources appear once with instructions and links" do
    items = WaitingWithoutCard.list()
    assert Enum.sort(Enum.map(items, & &1.kind)) == ~w(decision merge push report)
    assert length(Enum.uniq_by(items, & &1.id)) == 4
    assert Enum.all?(items, &(is_binary(&1.action) and &1.action != "" and is_binary(&1.href)))
    assert Enum.find(items, &(&1.kind == "merge")).href == "https://github.com/owner/repo/pull/12"
    decision = Enum.find(items, &(&1.kind == "decision"))
    assert decision.bead_id == "s-5"
    assert Map.get(decision, :detail) == "Blocks s-4, s-6"
  end

  test "human-merge reminders exclude PRs without a ticket link in the repo" do
    snapshot = Foreman.Forge.Store.get("sample").snapshot

    unlinked = %{
      "number" => 13,
      "state" => "open",
      "title" => "A teammate's change",
      "body" => "Unrelated work",
      "source_branch" => "teammate-change",
      "url" => "https://github.com/owner/repo/pull/13"
    }

    Foreman.Forge.Store.replace(
      "sample",
      "owner/repo",
      Map.update!(snapshot, "change_requests", &(&1 ++ [unlinked]))
    )

    reminders = Enum.filter(WaitingWithoutCard.list(), &(&1.kind == "merge"))
    assert Enum.map(reminders, & &1.href) == ["https://github.com/owner/repo/pull/12"]
  end

  test "push requests cover committed work until failed, including completed pushes" do
    for state <- ["pending", "approved", "executing", "done"] do
      r =
        Repo.insert!(%Foreman.Requests.Request{
          repo_key: "sample",
          bead_id: "s-1",
          kind: "push",
          actor: "pi",
          state: state,
          facts: %{}
        })

      refute Enum.any?(WaitingWithoutCard.list(), &(&1.kind == "push"))
      Repo.delete!(r)
    end

    Repo.insert!(%Foreman.Requests.Request{
      repo_key: "sample",
      bead_id: "s-1",
      kind: "push",
      actor: "pi",
      state: "failed",
      facts: %{}
    })

    assert Enum.any?(WaitingWithoutCard.list(), &(&1.kind == "push"))
  end

  test "disabled repos, no-forge pushes and board-merge PRs do not ask for human work" do
    config = Foreman.RuntimeState.config().config

    Repo.update_all("board_config",
      set: [config: put_in(config, ["repos", Access.at(0), "enabled"], false)]
    )

    assert WaitingWithoutCard.list() == []
    config = put_in(config, ["repos", Access.at(0), "merge_policy"], "board")
    Repo.update_all("board_config", set: [config: config])
    refute Enum.any?(WaitingWithoutCard.list(), &(&1.kind == "merge"))

    Repo.update_all("board_config",
      set: [config: put_in(config, ["repos", Access.at(0), "forge"], "none")]
    )

    refute Enum.any?(WaitingWithoutCard.list(), &(&1.kind == "push"))
  end

  test "pending cards cover items and resolved conditions remove them" do
    for id <- ["s-1", "s-2", "s-3", "s-5"] do
      {:ok, _} =
        Requests.ask({"sample", id}, "decision", %{
          "facts" => Foreman.DecisionFacts.valid(%{"question" => "Proceed?"})
        })
    end

    assert WaitingWithoutCard.list() == []
    for r <- Requests.pending(), do: Requests.resolve(r.id, :answer, %{"answer" => "Proceed"})
    assert length(WaitingWithoutCard.list()) == 4
    Overlay.apply_event({"sample", "s-1"}, :abandon)
    Overlay.apply_event({"sample", "s-3"}, :review)
    Overlay.apply_event({"sample", "s-5"}, :bead_closed)

    Foreman.Forge.Store.replace("sample", "owner/repo", %{
      "change_requests" => [
        %{"number" => 12, "state" => "merged", "title" => "s-2", "body" => "s-2"}
      ]
    })

    assert WaitingWithoutCard.list() == []
  end
end
