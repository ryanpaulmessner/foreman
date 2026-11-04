defmodule Foreman.CloseOutNagsTest do
  use Foreman.DataCase, async: false
  import Ecto.Query
  alias Foreman.{CloseOutNag, CloseOutNags, Overlay, Requests}

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
      for id <- ["s-1", "s-2", "s-3"],
          do: %{id: id, title: "Title " <> id, issue_type: "task", status: "in_progress"}

    Foreman.Beads.Projection.replace("sample", Enum.map_join(tickets, "\n", &Jason.encode!/1))

    Overlay.apply_event(
      {"sample", "s-1"},
      {:dispatch, %{window: "b1", branch: "feat/one", coordinator: "coord-a"}}
    )

    Overlay.apply_event({"sample", "s-1"}, {:report, %{path: "/tmp/r1.md"}})
    Overlay.apply_event({"sample", "s-2"}, {:dispatch, %{window: "b2", branch: "feat/two"}})
    Overlay.apply_event({"sample", "s-2"}, {:report, %{path: "/tmp/r2.md"}})
    parent = self()

    deliver = fn owner, text ->
      send(parent, {:note, owner, text})
      Process.get(:deliver_result, :ok)
    end

    %{t0: DateTime.utc_now(), deliver: deliver}
  end

  defp at(t0, minutes), do: DateTime.add(t0, minutes * 60, :second)
  defp run(c, minutes), do: CloseOutNags.run(now: at(c.t0, minutes), deliver: c.deliver)

  defp results(id),
    do: Enum.map(CloseOutNags.history({"sample", id}), &{&1.result, &1.owner, &1.reason})

  test "timings live in one place" do
    assert CloseOutNag.first_after() == 30 * 60
    assert CloseOutNag.repeat_every() == 3 * 60 * 60
  end

  test "stuck work sends one note at 30 min, again after 3 h, and stops when it changes", c do
    run(c, 29)
    refute_received {:note, _, _}

    run(c, 31)
    assert_received {:note, "coord-a", text}
    assert text =~ "Close-out work waits on you."
    assert text =~ "s-1 (sample): the report is not reviewed. Next: foreman review s-1"
    refute text =~ "s-2"
    assert results("s-1") == [{"delivered", "coord-a", nil}]

    run(c, 60)
    run(c, 31 + 179)
    refute_received {:note, _, _}

    run(c, 31 + 180)
    assert_received {:note, "coord-a", _}
    assert length(results("s-1")) == 2

    Overlay.apply_event({"sample", "s-1"}, :review)
    run(c, 31 + 180 + 181)
    run(c, 31 + 180 + 400)
    refute_received {:note, _, _}
    assert length(results("s-1")) == 2
  end

  test "a card change starts a new schedule; while a card is pending nothing is sent", c do
    run(c, 31)
    assert_received {:note, "coord-a", _}

    {:ok, card} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Ready?"})
      })

    run(c, 31 + 200)
    refute_received {:note, _, _}

    Requests.resolve(card.id, :answer, %{"answer" => "Proceed"})

    Repo.update_all(from(r in Foreman.Requests.Request, where: r.id == ^card.id),
      set: [updated_at: at(c.t0, 31 + 200)]
    )

    # The schedule restarts from the card change, not from the first note.
    run(c, 31 + 201)
    run(c, 31 + 229)
    refute_received {:note, _, _}
    run(c, 31 + 230)
    assert_received {:note, "coord-a", _}
  end

  test "an item that leaves the stuck list and returns unchanged starts a new schedule", c do
    status = fn s1 ->
      Foreman.Beads.Projection.replace(
        "sample",
        Enum.map_join(
          [{"s-1", s1}, {"s-2", "in_progress"}, {"s-3", "in_progress"}],
          "\n",
          fn {id, st} ->
            Jason.encode!(%{id: id, title: "Title " <> id, issue_type: "task", status: st})
          end
        )
      )
    end

    stuck = fn -> Enum.find(Foreman.WaitingWithoutCard.stuck(), &(&1.bead_id == "s-1")) end
    before = stuck.()

    run(c, 10)
    status.("parked")
    run(c, 15)

    assert Repo.one(from(n in "close_out_nags", where: n.bead_id == "s-1", select: n.state)) ==
             "cleared"

    status.("in_progress")
    assert stuck.().fingerprint == before.fingerprint
    run(c, 20)

    assert Repo.one(from(n in "close_out_nags", where: n.bead_id == "s-1", select: n.state)) ==
             "waiting"

    refute_received {:note, _, _}
    run(c, 31)
    assert_received {:note, "coord-a", text}
    assert text =~ "s-1 (sample)"
  end

  test "ownerless notes are recorded once with the reason and wait for a change", c do
    run(c, 31)
    assert results("s-2") == [{"ownerless", nil, "no coordinator recorded on dispatch"}]

    assert CloseOutNags.owner({"sample", "s-3"}) == {:error, "not dispatched"}
    Overlay.apply_event({"sample", "s-3"}, {:commit, %{sha: "abc"}}, %{actor: "claude"})

    Repo.update_all(from(t in "tickets", where: t.bead_id == "s-3"),
      set: [stage_changed_at: at(c.t0, -40)]
    )

    run(c, 32)

    assert results("s-3") == [
             {"ownerless", nil, "no session recorded on the coordinator's commit"}
           ]

    run(c, 32 + 60)
    assert length(results("s-2")) == 1
    assert length(results("s-3")) == 1
    run(c, 31 + 600)
    assert length(results("s-2")) == 1
    assert length(results("s-3")) == 1
  end

  test "undeliverable notes are recorded with the reason; a busy pane is tried again soon", c do
    Process.put(:deliver_result, {:error, :prompt_busy})
    run(c, 31)
    assert results("s-1") == [{"skipped", "coord-a", "pane busy"}]
    run(c, 31 + 9)
    assert length(results("s-1")) == 1
    run(c, 31 + 10)
    assert length(results("s-1")) == 2

    Process.put(:deliver_result, {:error, :window_gone})
    run(c, 31 + 20)
    assert List.last(results("s-1")) == {"skipped", "coord-a", "pane gone"}
    run(c, 31 + 40)
    assert length(results("s-1")) == 3
  end

  test "dispatch records the coordinator registered in the dispatching pane" do
    {:ok, _} =
      Foreman.SessionRegistry.register(%{
        "name" => "coord-b",
        "pane" => "%77",
        "workdir" => "/tmp",
        "harness" => "claude"
      })

    {:ok, %{request: request}} =
      Foreman.CLI.parse(~w(dispatch s-3 --window %80 --branch feat/three --session b3),
        tmux_pane: "%77",
        actor: "pi"
      )

    assert request["payload"]["coordinator_pane"] == "%77"
    assert {200, _} = Foreman.AgentCommands.execute(Map.put(request, "repo", "sample"))
    assert CloseOutNags.owner({"sample", "s-3"}) == {:ok, "coord-b"}

    {:ok, %{request: named}} =
      Foreman.CLI.parse(
        ~w(dispatch s-2 --window %81 --session b2 --coordinator coord-c),
        tmux_pane: "%77"
      )

    refute Map.has_key?(named["payload"], "coordinator_pane")
    assert named["payload"]["coordinator"] == "coord-c"
  end

  # The exact call pi-window makes from the coordinator's pane (fm-9mm.11).
  test "a pi-window dispatch with --name, --pi-session and --coordinator has an owner", c do
    {:ok, _} =
      Foreman.SessionRegistry.register(%{
        "name" => "coord-b",
        "pane" => "%77",
        "workdir" => "/tmp",
        "harness" => "claude"
      })

    pi_session = Ecto.UUID.generate()

    {:ok, %{request: request}} =
      Foreman.CLI.parse(
        ~w(dispatch s-3 --name b3 --pi-session #{pi_session} --coordinator coord-b
           --window %80 --harness pi --branch feat/three),
        tmux_pane: "%77",
        actor: "pi",
        session: "coord-b"
      )

    assert {200, _} = Foreman.AgentCommands.execute(Map.put(request, "repo", "sample"))
    assert CloseOutNags.owner({"sample", "s-3"}) == {:ok, "coord-b"}

    build = Foreman.AgentSessions.live_by_name("b3")
    assert build.kind == "build"
    assert build.pane_id == "%80"
    assert build.conversation_id == pi_session
    assert build.parent_id == Foreman.AgentSessions.live_by_name("coord-b").id

    Overlay.apply_event({"sample", "s-3"}, {:report, %{path: "/tmp/r3.md"}})
    run(c, 31)
    refute "ownerless" in Enum.map(results("s-3"), &elem(&1, 0))
    assert {"delivered", "coord-b", _} = List.last(results("s-3"))
  end

  test "a coordinator that built and committed the work itself owns it" do
    Foreman.Agent.event("sample", "s-3", %{
      "event" => "commit",
      "actor" => "claude",
      "session" => "coord-z",
      "payload" => %{"sha" => "abc"}
    })

    assert CloseOutNags.owner({"sample", "s-3"}) == {:ok, "coord-z"}
  end

  test "nag history appears on the ticket's history", c do
    run(c, 31)
    history = Foreman.Drilldown.ticket({"sample", "s-1"}).history
    note = List.last(history)
    assert note.event == "note_to_coordinator"
    assert note.outcome == "delivered"
    assert note.payload["owner"] == "coord-a"
    assert note.payload["body"] =~ "foreman review s-1"
  end

  test "one note per owner names every due ticket" do
    Overlay.apply_event({"sample", "s-3"}, {:dispatch, %{window: "w3", coordinator: "coord-a"}})

    Overlay.apply_event({"sample", "s-3"}, {:report, %{path: "/tmp/r3.md"}})
    parent = self()
    deliver = fn owner, text -> send(parent, {:note, owner, text}) && :ok end
    CloseOutNags.run(now: DateTime.add(DateTime.utc_now(), 31 * 60, :second), deliver: deliver)
    assert_received {:note, "coord-a", text}
    refute_received {:note, _, _}
    assert text =~ "s-1 (sample)"
    assert text =~ "s-3 (sample)"
    refute text =~ "s-2 (sample)"
  end

  test "a long decision line names five blocked tickets and the count of the rest" do
    item = %{bead_id: "s-9", repo_key: "sample", kind: "decision", blocks: ~w(a b c d e f g)}
    assert CloseOutNags.line(item) =~ "blocks a, b, c, d, e and 2 more and has no card"
  end

  test "the machine: due ticks ask for a note; the result picks the next wait" do
    t = ~U[2026-11-03 10:00:00Z]
    at = &%{now: DateTime.add(t, &1)}
    data = %{stuck_since: t, last_noted_at: nil}
    assert {:waiting, []} = CloseOutNag.step(:waiting, {:tick, at.(1799)}, data)
    assert {:waiting, [note: :owner]} = CloseOutNag.step(:waiting, {:tick, at.(1800)}, data)

    assert {:noted, [save: :attempt]} = CloseOutNag.step(:waiting, :delivered, data)
    assert {:noted, [save: :attempt]} = CloseOutNag.step(:waiting, :skipped, data)
    assert {:busy, [save: :attempt]} = CloseOutNag.step(:waiting, :pane_busy, data)
    assert {:ownerless, [save: :attempt]} = CloseOutNag.step(:waiting, :no_owner, data)

    noted = %{data | last_noted_at: t}
    assert {:noted, []} = CloseOutNag.step(:noted, {:tick, at.(10_799)}, noted)
    assert {:noted, [note: :owner]} = CloseOutNag.step(:noted, {:tick, at.(10_800)}, noted)
    assert {:busy, []} = CloseOutNag.step(:busy, {:tick, at.(599)}, noted)
    assert {:busy, [note: :owner]} = CloseOutNag.step(:busy, {:tick, at.(600)}, noted)
    assert {:ownerless, []} = CloseOutNag.step(:ownerless, {:tick, at.(99_999)}, noted)

    assert {:cleared, [save: :cleared]} = CloseOutNag.step(:noted, :resolved, noted)
    assert {:cleared, []} = CloseOutNag.step(:cleared, {:tick, at.(99_999)}, noted)
    assert {:error, _} = CloseOutNag.step(:cleared, :delivered, noted)

    for state <- [:waiting, :noted, :busy, :ownerless, :cleared],
        do: assert({:waiting, [save: :restart]} = CloseOutNag.step(state, :changed, noted))
  end

  test "the worker timer runs a pass on each tick", c do
    pid =
      start_supervised!(
        {Foreman.CloseOutNagMonitor,
         interval: :timer.hours(1), now: at(c.t0, 31), deliver: c.deliver}
      )

    Ecto.Adapters.SQL.Sandbox.allow(Foreman.Repo, self(), pid)
    send(pid, :tick)
    _ = :sys.get_state(pid)
    assert_received {:note, "coord-a", _}
  end

  test "the preview never sends notes", c do
    System.put_env("PREVIEW", "1")
    on_exit(fn -> System.delete_env("PREVIEW") end)
    assert {:error, _} = run(c, 31)
    refute_received {:note, _, _}
  end
end
