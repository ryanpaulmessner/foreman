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
      for {id, type, status} <- [
            {"s-1", "task", "open"},
            {"s-2", "task", "open"},
            {"s-3", "task", "open"},
            {"s-4", "task", "open"},
            {"s-5", "decision", "open"},
            {"s-6", "task", "open"},
            {"s-7", "task", "in_progress"},
            {"s-8", "task", "parked"},
            {"s-9", "task", "in_progress"}
          ] do
        %{
          id: id,
          title: "Title " <> id,
          issue_type: type,
          status: status,
          dependencies:
            if(id in ["s-4", "s-6"], do: [%{depends_on_id: "s-5", type: "blocks"}], else: [])
        }
      end

    Foreman.Beads.Projection.replace("sample", Enum.map_join(tickets, "\n", &Jason.encode!/1))
    Overlay.apply_event({"sample", "s-1"}, {:commit, %{sha: "abc"}}, %{actor: "claude"})
    Overlay.apply_event({"sample", "s-3"}, {:dispatch, %{window: "build", branch: "feature"}})
    Overlay.apply_event({"sample", "s-3"}, {:report, %{path: "/tmp/report.md"}})

    # s-7: committed; its branch has an open PR that does not name the ticket.
    Overlay.apply_event({"sample", "s-7"}, {:dispatch, %{window: "b7", branch: "feat/seven"}})
    Overlay.apply_event({"sample", "s-7"}, {:report, %{path: "/tmp/r7.md"}})
    Overlay.apply_event({"sample", "s-7"}, :review)
    Overlay.apply_event({"sample", "s-7"}, {:commit, %{sha: "def"}})

    # s-8: parked on purpose, with a report and an open PR.
    Overlay.apply_event({"sample", "s-8"}, {:dispatch, %{window: "b8", branch: "feat/eight"}})
    Overlay.apply_event({"sample", "s-8"}, {:report, %{path: "/tmp/r8.md"}})

    # s-9: shipped: its branch PR merged, but the ticket was left in progress.
    Overlay.apply_event({"sample", "s-9"}, {:dispatch, %{window: "b9", branch: "feat/nine"}})
    Overlay.apply_event({"sample", "s-9"}, {:report, %{path: "/tmp/r9.md"}})

    Foreman.Forge.Store.replace("sample", "owner/repo", %{
      "change_requests" => [
        pr(12, "s-2 Change", "s-2", "2026-11-01T10:00:00Z", body: "s-2"),
        pr(463, "Backlog note", "feat/seven", "2026-11-02T10:00:00Z"),
        pr(470, "Parked work", "feat/eight", "2026-11-02T11:00:00Z"),
        pr(368, "Shipped work", "feat/nine", "2026-10-30T10:00:00Z", state: "merged")
      ]
    })

    :ok
  end

  defp pr(number, title, branch, created, opts \\ []) do
    %{
      "number" => number,
      "state" => Keyword.get(opts, :state, "open"),
      "title" => title,
      "body" => Keyword.get(opts, :body, ""),
      "source_branch" => branch,
      "url" => "https://github.com/owner/repo/pull/#{number}",
      "created_at" => created
    }
  end

  defp merges, do: Enum.map(WaitingWithoutCard.list(), &{&1.number, &1.bead_ids})
  defp stuck, do: Enum.map(WaitingWithoutCard.stuck(), &{&1.bead_id, &1.kind})

  test "merge list holds open PRs matched by ticket link or head branch, oldest first" do
    assert [first, second] = WaitingWithoutCard.list()
    assert {first.number, first.bead_ids} == {12, ["s-2"]}
    assert first.url == "https://github.com/owner/repo/pull/12"
    assert first.title == "s-2 Change"
    assert first.opened_at == ~U[2026-11-01 10:00:00Z]
    assert {second.number, second.bead_ids} == {463, ["s-7"]}
  end

  test "parked tickets are never listed, as PRs or stuck work" do
    refute Enum.any?(merges(), &(elem(&1, 0) == 470))
    refute Enum.any?(stuck(), &(elem(&1, 0) == "s-8"))
  end

  test "stuck work is agent close-out only: reports, commits without push, decisions" do
    assert stuck() == [{"s-1", "push"}, {"s-3", "report"}, {"s-5", "decision"}]
    decision = Enum.find(WaitingWithoutCard.stuck(), &(&1.kind == "decision"))
    assert decision.blocks == ["s-4", "s-6"]
  end

  test "a ticket with an open PR on its branch is on the merge list, not stuck" do
    assert {463, ["s-7"]} in merges()
    refute Enum.any?(stuck(), &(elem(&1, 0) == "s-7"))
  end

  test "a shipped ticket left in progress is not stuck" do
    refute Enum.any?(stuck(), &(elem(&1, 0) == "s-9"))
    refute Enum.any?(merges(), &(elem(&1, 0) == 368))
  end

  test "PRs without a ticket link or a ticket branch are not listed" do
    snapshot = Foreman.Forge.Store.get("sample").snapshot

    Foreman.Forge.Store.replace(
      "sample",
      "owner/repo",
      Map.update!(
        snapshot,
        "change_requests",
        &(&1 ++ [pr(13, "A teammate's change", "teammate-change", "2026-11-01T09:00:00Z")])
      )
    )

    refute Enum.any?(merges(), &(elem(&1, 0) == 13))
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

      refute {"s-1", "push"} in stuck()
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

    assert {"s-1", "push"} in stuck()
  end

  test "a push card's branch matches its PR to the ticket" do
    Repo.insert!(%Foreman.Requests.Request{
      repo_key: "sample",
      bead_id: "s-1",
      kind: "push",
      actor: "claude",
      state: "done",
      facts: %{"remote_branch" => "feat/one"}
    })

    snapshot = Foreman.Forge.Store.get("sample").snapshot

    Foreman.Forge.Store.replace(
      "sample",
      "owner/repo",
      Map.update!(
        snapshot,
        "change_requests",
        &(&1 ++ [pr(480, "One", "feat/one", "2026-11-02T12:00:00Z")])
      )
    )

    assert {480, ["s-1"]} in merges()
  end

  test "disabled repos, no-forge pushes and board-merge PRs do not ask for human work" do
    config = Foreman.RuntimeState.config().config

    Repo.update_all("board_config",
      set: [config: put_in(config, ["repos", Access.at(0), "enabled"], false)]
    )

    assert WaitingWithoutCard.list() == []
    assert WaitingWithoutCard.stuck() == []
    config = put_in(config, ["repos", Access.at(0), "merge_policy"], "board")
    Repo.update_all("board_config", set: [config: config])
    assert WaitingWithoutCard.list() == []

    Repo.update_all("board_config",
      set: [config: put_in(config, ["repos", Access.at(0), "forge"], "none")]
    )

    refute Enum.any?(stuck(), &(elem(&1, 1) == "push"))
  end

  test "pending cards cover items; a card or stage change moves the fingerprint" do
    before = Map.new(WaitingWithoutCard.stuck(), &{&1.bead_id, &1.fingerprint})

    for id <- ["s-1", "s-2", "s-3", "s-5", "s-7"] do
      {:ok, _} =
        Requests.ask({"sample", id}, "decision", %{
          "facts" => Foreman.DecisionFacts.valid(%{"question" => "Proceed?"})
        })
    end

    assert WaitingWithoutCard.list() == []
    assert WaitingWithoutCard.stuck() == []
    for r <- Requests.pending(), do: Requests.resolve(r.id, :answer, %{"answer" => "Proceed"})
    assert length(WaitingWithoutCard.list()) == 2
    assert stuck() == [{"s-1", "push"}, {"s-3", "report"}, {"s-5", "decision"}]

    for item <- WaitingWithoutCard.stuck() do
      assert item.fingerprint != before[item.bead_id]
      assert DateTime.compare(item.since, ~U[2026-01-01 00:00:00Z]) == :gt
    end

    Overlay.apply_event({"sample", "s-1"}, :abandon)
    Overlay.apply_event({"sample", "s-3"}, :review)
    Overlay.apply_event({"sample", "s-5"}, :bead_closed)

    Foreman.Forge.Store.replace("sample", "owner/repo", %{
      "change_requests" => [
        %{"number" => 12, "state" => "merged", "title" => "s-2", "body" => "s-2"},
        %{"number" => 463, "state" => "merged", "title" => "x", "source_branch" => "feat/seven"}
      ]
    })

    assert WaitingWithoutCard.list() == []
    assert WaitingWithoutCard.stuck() == []
  end
end
