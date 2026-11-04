defmodule Foreman.SessionLifecycleContextTest do
  @moduledoc """
  The lifecycle machine on `agent_sessions` rows: writers, card events, the monitor's
  end of a pane, SessionMachine transitions, the broadcast and the rules that need rows.
  """
  use Foreman.DataCase, async: false
  use Mimic
  import Foreman.AgentSessionFixtures
  alias Foreman.{AgentSessions, PlanningSession, Requests}

  @key {"sample", "s-1"}

  setup do
    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "s-1", title: "Ticket", issue_type: "task", status: "open"})
    )

    parent = self()

    Mimic.stub(Foreman.Events, :broadcast, fn kind, key ->
      send(parent, {:broadcast, kind, key})
      :ok
    end)

    :ok
  end

  defp register(name, pane, harness, extra \\ %{}) do
    {:ok, %{id: id}} =
      Foreman.SessionRegistry.register(
        Map.merge(
          %{"name" => name, "pane" => pane, "workdir" => "/tmp", "harness" => harness},
          extra
        )
      )

    AgentSessions.get(id)
  end

  defp ask(session, pane) do
    {:ok, request} =
      Requests.ask(@key, "decision", %{
        "actor" => "pi",
        "session" => session,
        "tmux_pane" => pane,
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Ship?"})
      })

    request
  end

  defp waiting(session, pane, facts) do
    {:ok, request} =
      Requests.create(@key, "session_waiting", %{
        "actor" => "claude",
        "session" => session,
        "tmux_pane" => pane,
        "facts" => facts
      })

    request
  end

  defp state(row), do: AgentSessions.get(row.id).state

  defp flush_broadcasts do
    receive do
      {:broadcast, _, _} -> flush_broadcasts()
    after
      0 -> :ok
    end
  end

  test "a writer creates the row in starting and broadcasts :sessions_changed" do
    row = register("b1", "%2", "pi")
    assert row.state == "starting"
    assert row.state_at
    refute row.ended_at
    assert_received {:broadcast, :sessions_changed, id} when id == row.id
  end

  test "asked: an accepted card waits on you; the last card closing makes the row idle" do
    row = register("b1", "%2", "pi")
    first = ask("b1", "%2")
    assert first.agent_session_id == row.id
    assert state(row) == "waiting.question"

    second = ask("b1", "%2")
    assert state(row) == "waiting.question"

    {:ok, _} = Requests.resolve(first.id, :answer, %{"answer" => "Yes"})
    assert state(row) == "waiting.question"

    {:ok, _} = Requests.resolve(second.id, :answer, %{"answer" => "Yes"})
    assert state(row) == "idle"
  end

  test "a permission prompt waits on you until its request clears" do
    row = register("coord", "%1", "claude")
    request = waiting("coord", "%1", %{"reason" => "permission", "tool" => "abc"})
    assert state(row) == "waiting.permission"

    {:ok, _} = Requests.resolve(request.id, :facts_changed, %{"reason" => "session_resumed"})
    assert state(row) == "working"
  end

  test "a usage limit waits on you; Continue is the only claim, output resumes it" do
    row = register("b1", "%2", "pi")

    waiting("b1", "%2", %{
      "reason" => "usage_limit",
      "provider" => "Anthropic",
      "reset_at" => "3pm"
    })

    assert state(row) == "waiting.usage_limit"

    assert {:ok, _, [send: :continue]} = AgentSessions.fire(row, :continue)
    assert state(row) == "waiting.usage_limit"

    assert %{reset_at: "3pm", open_cards: 1} =
             AgentSessions.label_facts(AgentSessions.get(row.id))

    assert {:ok, _, [clear: :request]} = AgentSessions.observe_output(row.id, "w:1")
    assert state(row) == "working"
  end

  test "a coordinator posting its build's usage limit names the build's row" do
    coord = register("coord", "%1", "claude")
    {:ok, other} = AgentSessions.create(%{name: "b0", kind: "build", parent_id: coord.id})

    {:ok, build} =
      AgentSessions.create(%{
        name: "b1",
        kind: "build",
        harness: "pi",
        parent_id: coord.id,
        project: "sample",
        ticket: "s-1"
      })

    request = waiting("coord", "%1", %{"reason" => "usage_limit", "provider" => "OpenAI"})
    assert request.agent_session_id == build.id
    assert state(build) == "waiting.usage_limit"
    assert state(coord) == "starting"
    assert state(other) == "starting"

    # The coordinator's own questions still name the coordinator.
    assert ask("coord", "%1").agent_session_id == coord.id
  end

  test "the monitor's pane_gone ends the row and sets ended_at" do
    gone = register("gone", "%1", "pi")
    assert :ok = Foreman.SessionRegistry.reconcile(runner: fn _, _, _ -> {"", 0} end)
    row = AgentSessions.get(gone.id)
    assert row.state == "ended"
    assert row.ended_at
    assert row.state_at == row.ended_at
  end

  test "claimed events outside the table are refused and change nothing" do
    row = register("b1", "%2", "pi")
    flush_broadcasts()

    assert {:error, {:invalid, :starting, :park}} = AgentSessions.fire(row, :park)
    assert {:error, {:invalid, :starting, :resume}} = AgentSessions.fire(row, :resume)
    assert {:ok, _, []} = AgentSessions.fire(row, :last_card_closed)
    assert AgentSessions.get(row.id) == row
    refute_received {:broadcast, :sessions_changed, _}
  end

  describe "SessionMachine transitions fire the matching event in the same transaction" do
    setup do
      main = register("coordinator", "%1", "claude")

      planning =
        Repo.insert!(%PlanningSession{
          project: "sample",
          ticket: "s-1",
          window: "@4",
          workdir: "/tmp",
          state: :starting,
          launched_at: DateTime.utc_now()
        })

      row = AgentSessions.sync_planning(planning)
      %{main: main, planning: %{planning | agent_session_id: row.id}, row: row}
    end

    test "launch writes the row in starting", c do
      assert c.row.state == "starting"
      assert c.row.kind == "epic_coordinator"
    end

    test "idle_timeout parks an epic coordinator", c do
      row = AgentSessions.sync_planning(%{c.planning | state: :parked}, event: :idle_timeout)
      assert row.state == "parked"
      assert row.ended_at
    end

    test "a window closed by hand ends the row while the planning row parks", c do
      row = AgentSessions.sync_planning(%{c.planning | state: :parked}, event: :window_gone)
      assert row.state == "ended"
    end

    test "exited ends the row; relaunch resumes the same row", c do
      ended = AgentSessions.sync_planning(%{c.planning | state: :ended}, event: :exited)
      assert ended.state == "ended"

      resumed = AgentSessions.sync_planning(%{c.planning | state: :starting}, event: :relaunch)
      assert resumed.id == c.row.id
      assert resumed.state == "starting"
      refute resumed.ended_at
    end

    test "through Sessions: an idle-timeout park in tmux parks the row", c do
      Foreman.SessionTmux
      |> Mimic.stub(:observe, fn _, _ -> {:ok, %{window: "@4", state: :running}} end)
      |> Mimic.stub(:attached?, fn _, _ -> {:ok, false} end)
      |> Mimic.stub(:park, fn _, _ -> :ok end)

      Repo.update_all(from(p in PlanningSession, where: p.ticket == "s-1"),
        set: [state: :running]
      )

      assert :ok =
               Foreman.Sessions.reconcile(
                 idle_timeout: 0,
                 runner: fn _, _, _ -> {"%1\t@1\tc\tcoordinator\t1\t\t\n", 0} end
               )

      assert state(c.row) == "parked"
    end
  end

  describe "rules that need rows" do
    test "R6: the main coordinator's board row ends rather than parks" do
      {:ok, main, _} = Foreman.Sessions.prepare_coordinator(:fresh, workdir: "/tmp", pane: "%8")
      planning = Foreman.Sessions.coordinator()
      row = AgentSessions.sync_planning(%{planning | state: :parked}, event: :idle_timeout)
      assert row.id == main.session_id
      assert row.state == "ended"
    end

    test "R7: a dead row does not resume while another live row has its name" do
      old = register("b1", "%2", "pi", %{"workdir" => "/tmp"}) |> AgentSessions.end_session()
      register("b1", "%3", "pi")

      assert {:error, :name_taken} =
               AgentSessions.fire(old, :resume, data: %{resumable: true})

      assert state(old) == "ended"
    end

    test "R8: a coordinator ending leaves its builds live, and they show Parent ended" do
      coord = register("coord", "%1", "claude")
      build = register("b1", "%2", "pi", %{"parent" => "coord"})
      assert build.parent_id == coord.id

      AgentSessions.fire(coord, :stop)
      assert state(coord) == "ended"
      assert state(build) == "starting"

      facts = AgentSessions.label_facts(AgentSessions.get(build.id))
      assert facts.parent_ended_at == AgentSessions.get(coord.id).ended_at
      assert %{second: "Parent ended just now"} = ForemanWeb.SessionState.view(facts)
    end

    test "R9 and R2: a session that ends with an open card keeps the card and waits on you" do
      row = register("b1", "%2", "pi")
      request = ask("b1", "%2")

      assert {:ok, _, [save: :capture, close: :pane]} = AgentSessions.fire(row, :stop)
      assert Requests.get(request.id).state == "pending"

      ended = AgentSessions.get(row.id)
      assert ended.state == "ended"

      assert %{label: "Waiting on you", second: "ended just now"} =
               ended |> AgentSessions.label_facts() |> ForemanWeb.SessionState.view()
    end

    test "R4: resumable needs the conversation id; for Pi also the worktree and session file" do
      dir = Path.join(System.tmp_dir!(), "lc-pi-#{System.unique_integer([:positive])}")
      worktree = Path.join(dir, "work")
      File.mkdir_p!(worktree)
      sessions = Path.join(dir, "sessions")
      Application.put_env(:foreman, :pi_sessions_dir, sessions)

      on_exit(fn ->
        Application.delete_env(:foreman, :pi_sessions_dir)
        File.rm_rf!(dir)
      end)

      pi = %{harness: "pi", conversation_id: "abc", workdir: worktree}
      refute AgentSessions.resumable?(pi)

      project =
        Path.join(
          sessions,
          "--" <> String.replace(String.trim_leading(worktree, "/"), "/", "-") <> "--"
        )

      File.mkdir_p!(project)
      File.write!(Path.join(project, "2026-11-04T10-00-00-000Z_abc.jsonl"), "")
      assert AgentSessions.resumable?(pi)
      refute AgentSessions.resumable?(%{pi | conversation_id: nil})
      refute AgentSessions.resumable?(%{pi | workdir: Path.join(dir, "gone")})

      assert AgentSessions.resumable?(%{harness: "claude", conversation_id: "uuid"})
      refute AgentSessions.resumable?(%{harness: "claude", conversation_id: nil})

      # The guard reads it: a dead Pi build without its session file relaunches instead.
      row = agent_session(name: "b9", harness: "pi", conversation_id: "zzz", workdir: worktree)
      row = AgentSessions.end_session(row)
      assert {:error, {:invalid, :ended, :resume}} = AgentSessions.fire(row, :resume)

      assert {:ok, _, [resume: :parent, note: :relaunch]} =
               AgentSessions.fire(row, :relaunch_build)
    end
  end
end
