defmodule Foreman.SessionRegistrationTest do
  use Foreman.DataCase, async: true

  test "cards without rows fall back to a live name, but unknown names stay unknown" do
    request = %{
      session: "build",
      actor: "pi",
      repo_key: "sample",
      bead_id: "s-1",
      kind: "session_waiting",
      facts: %{"target" => "external", "pane" => "%49"}
    }

    runner = fn _, _, _ -> {"%50\t@2\tcoordinator\tother-name\t0\tbuild\t\n", 0} end

    assert %{target: "%50", name: "build"} =
             Foreman.RequestSource.for_request(request, runner: runner)

    assert nil ==
             Foreman.RequestSource.for_request(%{request | session: "unknown"}, runner: runner)
  end

  test "a registration during a liveness check cannot be ended by the old listing" do
    attrs = %{"name" => "coord", "pane" => "%41", "workdir" => "/tmp", "harness" => "claude"}
    assert {:ok, _} = Foreman.SessionRegistry.register(attrs)

    runner = fn _, _, _ ->
      assert {:ok, _} = Foreman.SessionRegistry.register(Map.put(attrs, "pane", "%42"))
      {"", 0}
    end

    assert :ok = Foreman.SessionRegistry.reconcile(runner: runner)
    assert Repo.one(from s in "sessions", select: {s.window, s.ended_at}) == {"%42", nil}
  end

  test "a missing pane ends its row but a failed listing does not" do
    attrs = %{"name" => "coord", "pane" => "%41", "workdir" => "/tmp", "harness" => "claude"}
    assert {:ok, _} = Foreman.SessionRegistry.register(attrs)

    assert {:error, :tmux_unavailable} =
             Foreman.SessionRegistry.reconcile(runner: fn _, _, _ -> {"unavailable", 1} end)

    assert Repo.one(from s in "sessions", select: s.ended_at) == nil

    assert :ok =
             Foreman.SessionRegistry.reconcile(
               runner: fn _, _, _ -> {"%41\t@1\tcoordinator\tcoord\t1\t\t\n", 0} end
             )

    assert Repo.one(from s in "sessions", select: s.ended_at) == nil
    assert :ok = Foreman.SessionRegistry.reconcile(runner: fn _, _, _ -> {"", 0} end)
    assert %NaiveDateTime{} = Repo.one(from s in "sessions", select: s.ended_at)
    assert {:ok, _} = Foreman.SessionRegistry.register(Map.put(attrs, "pane", "%42"))
    assert Repo.one(from s in "sessions", select: s.ended_at) == nil
  end

  test "register updates a named coordinator without borrowing its dispatched build" do
    args = ~w(session register --name coord --pane %41 --workdir /tmp --harness claude)
    assert {:ok, %{request: command}} = Foreman.CLI.parse(args)
    assert {200, _} = Foreman.AgentCommands.execute(command)
    assert {200, _} = Foreman.AgentCommands.execute(Map.put(command, "pane", "%42"))

    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "s-1", title: "Ticket", issue_type: "task", status: "open"})
    )

    assert {:ok, %{request: dispatch}} =
             Foreman.CLI.parse(~w(dispatch s-1 --session build --window %50 --harness pi))

    assert {200, _} = Foreman.Agent.event("sample", "s-1", dispatch)

    {:ok, card} =
      Foreman.Requests.ask({"sample", "s-1"}, "decision", %{
        "actor" => "claude",
        "session" => "coord",
        "facts" => %{"question" => "Ship?"}
      })

    assert %{target: "%42", name: "coord", harness: "claude"} =
             Foreman.RequestSource.for_request(card)

    {:ok, build_card} =
      Foreman.Requests.ask({"sample", "s-1"}, "decision", %{
        "actor" => "pi",
        "session" => "build",
        "facts" => %{"question" => "Build ready?"}
      })

    assert %{target: "%50", harness: "pi"} = Foreman.RequestSource.for_request(build_card)

    assert :ok =
             Foreman.SessionRegistry.reconcile(
               runner: fn _, _, _ -> {"%42\t@1\tcoordinator\tcoord\t1\t\t\n", 0} end
             )

    assert %{ended_at: %NaiveDateTime{}} = Foreman.RequestSource.for_request(build_card)
    refute Map.has_key?(Foreman.RequestSource.for_request(card), :ended_at)

    assert Repo.aggregate(
             from(s in "sessions", where: fragment("?->>'session'", s.details) == "coord"),
             :count
           ) == 1
  end
end
