defmodule Foreman.AgentSessionsTest do
  use Foreman.DataCase, async: false
  import Foreman.AgentSessionFixtures
  alias Foreman.{AgentSession, AgentSessions, Requests}

  setup do
    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "s-1", title: "Ticket", issue_type: "task", status: "open"})
    )

    :ok
  end

  defp ask(params) do
    Requests.ask(
      {"sample", "s-1"},
      "decision",
      Map.merge(
        %{"actor" => "pi", "facts" => Foreman.DecisionFacts.valid(%{"question" => "Ship?"})},
        params
      )
    )
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

  describe "lookups" do
    test "by id, by live name and by live pane on its server" do
      row = agent_session(name: "b1", pane_id: "%7")

      assert AgentSessions.get(row.id).id == row.id
      assert AgentSessions.get("not-a-uuid") == nil
      assert AgentSessions.live_by_name("b1").id == row.id
      assert AgentSessions.live_by_pane("%7", "default").id == row.id
      assert AgentSessions.live_by_pane("%7", "board") == nil

      AgentSessions.end_session(row)
      assert AgentSessions.live_by_name("b1") == nil
      assert AgentSessions.live_by_pane("%7", "default") == nil
      assert %AgentSession{ended_at: %DateTime{}} = AgentSessions.get(row.id)
    end

    test "two live rows with one name are refused; the name is free once the first ends" do
      first = agent_session(name: "same", pane_id: "%1")

      assert {:error, changeset} =
               AgentSessions.create(%{name: "same", kind: "build", pane_id: "%2"})

      assert %{name: ["is taken by a live session"]} = errors_on(changeset)

      AgentSessions.end_session(first)

      assert {:ok, second} = AgentSessions.create(%{name: "same", kind: "build", pane_id: "%2"})
      assert second.id != first.id
      assert AgentSessions.live_by_name("same").id == second.id
      # The old row keeps its id, so old cards still open it.
      assert AgentSessions.get(first.id).ended_at
    end

    test "the main coordinator is the live one, else the latest" do
      old =
        agent_session(
          name: "coordinator",
          kind: "main_coordinator",
          started_at: ~U[2020-01-01 00:00:00Z]
        )

      AgentSessions.end_session(old)
      assert AgentSessions.main_coordinator().id == old.id

      live = agent_session(name: "coordinator", kind: "main_coordinator")
      assert AgentSessions.main_coordinator().id == live.id
    end
  end

  describe "ask resolution" do
    test "a registered pane stores its own row, by name or by pane" do
      coord = register("coord", "%1", "claude")
      build = register("b1", "%2", "pi")

      {:ok, by_name} = ask(%{"session" => "b1", "tmux_pane" => "%2"})
      assert by_name.agent_session_id == build.id

      {:ok, by_pane} = ask(%{"session" => nil, "tmux_pane" => "%1"})
      assert by_pane.agent_session_id == coord.id

      # Stored on the request, so a later row with the same name does not move the card.
      AgentSessions.end_session(build)
      register("b1", "%9", "pi")
      assert Requests.get(by_name.id).agent_session_id == build.id
    end

    test "a build never resolves to its coordinator's row" do
      coord = register("coord", "%1", "claude")

      # The build inherited the coordinator's FOREMAN_SESSION but asks from its own pane.
      {:ok, unregistered} = ask(%{"session" => "coord", "tmux_pane" => "%2"})
      assert unregistered.agent_session_id == nil

      build = register("b1", "%2", "pi")
      {:ok, registered} = ask(%{"session" => "coord", "tmux_pane" => "%2"})
      assert registered.agent_session_id == build.id
      refute registered.agent_session_id == coord.id
    end

    test "a pane build dispatched with --name asks as itself (spec acceptance 2 shape)" do
      coord = register("coord", "%1", "claude")
      pi_session = Ecto.UUID.generate()

      {:ok, %{request: dispatch}} =
        Foreman.CLI.parse(
          ~w(dispatch s-1 --name b2 --pi-session #{pi_session} --window %3 --harness pi --model m --workdir /tmp/b2 --branch feat/b2),
          session: "coord",
          actor: "pi",
          tmux_pane: "%1",
          tmux: "/private/tmp/tmux-1/default,1,0"
        )

      assert {200, _} = Foreman.Agent.event("sample", "s-1", dispatch)

      build = AgentSessions.live_by_name("b2")

      assert %AgentSession{
               kind: "build",
               pane_id: "%3",
               conversation_id: ^pi_session,
               project: "sample",
               ticket: "s-1",
               branch: "feat/b2",
               model: "m"
             } = build

      assert build.parent_id == coord.id

      {:ok, card} =
        ask(%{
          "session" => "b2",
          "tmux_pane" => "%3",
          "tmux_socket" => "/private/tmp/tmux-1/default"
        })

      assert card.agent_session_id == build.id

      # The dispatch row points at the build, and the coordinator still owns close-out.
      assert [{id, "b2", "coord"}] =
               Repo.all(
                 from s in "sessions",
                   where: s.bead_id == "s-1",
                   select:
                     {type(s.agent_session_id, :binary_id), fragment("?->>'session'", s.details),
                      fragment("?->>'coordinator'", s.details)}
               )

      assert id == build.id
    end

    test "board hooks resolve by the conversation id" do
      planning =
        Repo.insert!(%Foreman.PlanningSession{
          project: "sample",
          ticket: "s-1",
          window: "@4",
          workdir: "/tmp",
          state: :running,
          launched_at: DateTime.utc_now()
        })

      row = AgentSessions.sync_planning(planning)
      assert row.id == planning.session_id

      {:ok, card} =
        ask(%{
          "session" => planning.session_id,
          "tmux_pane" => "%5",
          "tmux_socket" => "/tmp/x/foreman"
        })

      assert card.agent_session_id == row.id
    end

    test "an unknown shell is accepted, warned and has no row" do
      register("coord", "%1", "claude")

      for params <- [
            %{"session" => "nobody", "tmux_pane" => "%77"},
            %{"session" => nil, "tmux_pane" => nil},
            # A pane on a tmux server the board does not read never matches.
            %{"session" => nil, "tmux_pane" => "%1", "tmux_socket" => "/tmp/other/scratch"}
          ] do
        {:ok, card} = ask(params)
        assert card.state == "pending"
        assert card.agent_session_id == nil
      end

      assert AgentSessions.resolve_asker(%{"session" => "nobody", "tmux_pane" => "%77"}) ==
               {:unknown,
                "The board does not know this session (name nobody, pane %77). The card shows that the source is unknown."}

      assert {:unknown, "The board does not know this session (name unset, pane unset)." <> _} =
               AgentSessions.resolve_asker(%{})
    end
  end

  describe "writers" do
    test "register --parent: builds under their coordinator; coordinators under the main one" do
      main = register("coordinator", "%1", "claude")
      assert main.kind == "main_coordinator"

      epic = register("ai-chat", "%2", "claude")
      assert {epic.kind, epic.parent_id} == {"epic_coordinator", main.id}

      relay = register("relay-1", "%3", "pi", %{"parent" => "ai-chat"})
      assert {relay.kind, relay.parent_id} == {"build", epic.id}

      # An unknown parent is not an error: the row has no parent yet.
      orphan = register("relay-2", "%4", "pi", %{"parent" => "nobody"})
      assert orphan.parent_id == nil
    end

    test "re-registering on the same pane keeps the row; another pane starts a new one" do
      first = register("coord", "%1", "claude")
      assert register("coord", "%1", "claude").id == first.id

      moved = register("coord", "%2", "claude")
      refute moved.id == first.id
      assert AgentSessions.get(first.id).ended_at
      assert AgentSessions.live_by_name("coord").id == moved.id
    end

    test "a registration and a later dispatch of one build share a row" do
      register("coord", "%1", "claude")
      build = register("b1", "%5", "pi")

      {:ok, %{request: dispatch}} =
        Foreman.CLI.parse(~w(dispatch s-1 --session b1 --window %5 --harness pi),
          session: "b1",
          tmux_pane: "%1",
          tmux: ""
        )

      assert {200, _} = Foreman.Agent.event("sample", "s-1", dispatch)
      row = AgentSessions.get(build.id)
      assert row.ticket == "s-1"
      assert row.parent_id == AgentSessions.live_by_name("coord").id
      assert AgentSessions.live_by_name("b1").id == build.id
    end

    test "a dispatch that names a live coordinator never takes over its row" do
      coord = register("coord", "%1", "claude")

      {:ok, %{request: dispatch}} =
        Foreman.CLI.parse(~w(dispatch s-1 --session coord --window %5 --harness pi),
          session: "coord",
          tmux: ""
        )

      assert {200, _} = Foreman.Agent.event("sample", "s-1", dispatch)
      assert AgentSessions.get(coord.id).pane_id == "%1"
      assert AgentSessions.get(coord.id).ticket == nil

      assert Repo.one(from s in "sessions", where: s.bead_id == "s-1", select: s.agent_session_id) ==
               nil
    end

    test "reconcile ends rows whose pane is gone, not ones claimed after the listing" do
      gone = register("gone", "%1", "pi")
      kept = register("kept", "%2", "pi")

      runner = fn _, _, _ ->
        # A claim during the listing moves last_seen_at, so this row is not ended.
        register("late", "%3", "pi")
        {"%2\t@1\tcoordinator\tkept\t1\t\t\n", 0}
      end

      assert :ok = Foreman.SessionRegistry.reconcile(runner: runner)
      assert AgentSessions.get(gone.id).ended_at
      refute AgentSessions.get(kept.id).ended_at
      refute AgentSessions.live_by_name("late").ended_at
    end
  end

  describe "board launch" do
    test "the main coordinator's row shares the planning UUID and a fresh one replaces it" do
      assert {:ok, first, :fresh} =
               Foreman.Sessions.prepare_coordinator(:fresh, workdir: "/tmp", pane: "%8")

      row = AgentSessions.get(first.session_id)

      assert %AgentSession{
               kind: "main_coordinator",
               name: "coordinator",
               tmux_server: "board",
               pane_id: "%8",
               parent_id: nil
             } = row

      assert row.conversation_id == first.session_id
      assert Repo.get(Foreman.PlanningSession, first.session_id).agent_session_id == row.id

      # The first conversation ends; its row stays for old cards.
      Repo.update_all(from(p in Foreman.PlanningSession), set: [state: :ended])
      assert {:ok, second, :fresh} = Foreman.Sessions.prepare_coordinator(:fresh, workdir: "/tmp")
      refute second.session_id == first.session_id
      assert AgentSessions.get(first.session_id).ended_at
      assert AgentSessions.live_by_name("coordinator").id == second.session_id
    end

    test "a planning session is an epic coordinator under the main one, live while it runs" do
      main = register("coordinator", "%1", "claude")

      planning =
        Repo.insert!(%Foreman.PlanningSession{
          project: "sample",
          ticket: "s-1",
          window: "@4",
          workdir: "/tmp",
          state: :starting,
          launched_at: DateTime.utc_now()
        })

      row = AgentSessions.sync_planning(planning)

      assert %AgentSession{
               kind: "epic_coordinator",
               name: "s-1",
               project: "sample",
               ticket: "s-1"
             } =
               row

      assert row.parent_id == main.id
      refute row.ended_at

      parked = %{planning | state: :parked, agent_session_id: row.id}
      assert AgentSessions.sync_planning(parked).ended_at

      # Relaunch keeps the conversation and its row.
      relaunched = AgentSessions.sync_planning(%{parked | state: :starting})
      assert relaunched.id == row.id
      refute relaunched.ended_at
    end
  end
end
