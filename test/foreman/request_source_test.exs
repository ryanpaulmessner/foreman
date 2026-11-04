defmodule Foreman.RequestSourceTest do
  use Foreman.DataCase, async: false
  alias Foreman.RequestSource

  import Foreman.AgentSessionFixtures

  test "a card's source is its own row: pane target, or window name before a pane is known" do
    for {pane, target} <- [{"%464", "%464"}, {nil, "relay-build"}] do
      row = agent_session(name: "relay-build", pane_id: pane)
      request = %{session: "coordinator", actor: "claude", agent_session_id: row.id}

      assert RequestSource.for_request(request) == %{
               name: "relay-build",
               harness: "pi",
               target: target,
               server: :default,
               agent_session_id: row.id,
               kind: "build"
             }

      Foreman.AgentSessions.end_session(row)
    end
  end

  test "an ended row keeps its source and says when it ended" do
    row = agent_session(name: "build", pane_id: "%9") |> Foreman.AgentSessions.end_session()

    assert %{name: "build", ended_at: %DateTime{}} =
             RequestSource.for_request(%{session: "build", agent_session_id: row.id})
  end

  test "a card asked since identity rows existed never matches by name at render" do
    agent_session(name: "build", pane_id: "%9")

    assert RequestSource.for_request(%{
             session: "build",
             agent_session_id: nil,
             inserted_at: DateTime.utc_now()
           }) == nil
  end

  test "a card from before identity rows uses the row live under its name when it was asked" do
    asked = ~U[2020-01-01 12:00:00Z]

    agent_session(
      name: "build",
      pane_id: "%8",
      started_at: ~U[2020-01-01 11:00:00Z],
      ended_at: ~U[2020-01-01 13:00:00Z]
    )

    agent_session(name: "build", pane_id: "%9", started_at: ~U[2020-01-02 00:00:00Z])

    assert %{target: "%8"} =
             RequestSource.for_request(%{session: "build", inserted_at: asked})

    assert RequestSource.for_request(%{session: "other", inserted_at: asked}) == nil
    assert RequestSource.for_request(%{session: nil, inserted_at: asked}) == nil
  end

  test "board rows target their planning window on the board server" do
    planning =
      Foreman.Repo.insert!(%Foreman.PlanningSession{
        project: "sample",
        ticket: "s-1",
        window: "@12",
        workdir: "/tmp",
        state: :running,
        launched_at: DateTime.utc_now()
      })

    row = Foreman.AgentSessions.sync_planning(planning)

    assert %{name: "s-1", harness: "claude", target: "@12", server: :board} =
             RequestSource.for_request(%{session: planning.session_id, agent_session_id: row.id})
  end

  test "configured sockets are used internally but copied commands use the default server" do
    for {server, key} <- [board: :planning_tmux_socket, default: :external_tmux_socket] do
      old = Application.fetch_env(:foreman, key)

      on_exit(fn ->
        case old do
          {:ok, value} -> Application.put_env(:foreman, key, value)
          :error -> Application.delete_env(:foreman, key)
        end
      end)

      Application.put_env(:foreman, key, "custom-'socket")
      source = %{server: server, target: "%464"}

      runner = fn "tmux", args, _ ->
        assert Enum.take(args, 3) == ["-N", "-L", "custom-'socket"]
        {"", 1}
      end

      assert RequestSource.focus(source, runner: runner) == {:error, :tmux_unavailable}
      refute RequestSource.command(source) =~ " -L "
      assert RequestSource.command(source) =~ "tmux select-window"
    end
  end

  test "closed windows return window_gone without focus writes" do
    assert RequestSource.focus(%{server: :default, target: "%464"},
             runner: fn _, args, _ ->
               assert "list-panes" in args
               {"", 0}
             end
           ) == {:error, :window_gone}
  end

  test "focus uses only read and focus commands on the selected server" do
    source = %{name: "build", harness: "pi", target: "%464", server: :default}

    runner = fn "tmux", args, _ ->
      send(self(), {:tmux, args})

      cond do
        "list-panes" in args -> {"%464\t@12\twork\tbuild\t1\n", 0}
        "list-clients" in args -> {"123\t/dev/ttys001\n", 0}
        true -> {"", 0}
      end
    end

    assert RequestSource.focus(source, runner: runner, platform: {:unix, :linux}) == :ok
    assert_receive {:tmux, ["-N", "-L", "default", "list-panes" | _]}
    assert_receive {:tmux, ["-N", "-L", "default", "list-clients" | _]}

    assert_receive {:tmux,
                    ["-N", "-L", "default", "switch-client", "-c", "/dev/ttys001", "-t", "%464"]}

    assert RequestSource.command(source) ==
             ~S|tmux select-window -t '%464' && tmux select-pane -t '%464' && if [ -n "$TMUX" ]; then tmux switch-client -t "$(tmux display-message -p -t '%464' '#{session_id}')"; else tmux attach-session -t "$(tmux display-message -p -t '%464' '#{session_id}')"; fi|
  end

  test "a window target keeps its active pane" do
    source = %{target: "build", server: :default}

    runner = fn "tmux", args, _ ->
      cond do
        "list-panes" in args ->
          {"%1\t@12\twork\tbuild\t0\n%2\t@12\twork\tbuild\t1\n", 0}

        "list-clients" in args ->
          {"1\t/dev/ttys001\n", 0}

        "switch-client" in args ->
          assert List.last(args) == "%2"
          {"", 0}

        true ->
          {"", 0}
      end
    end

    assert RequestSource.focus(source, runner: runner, platform: {:unix, :linux}) == :ok
  end

  test "no attached client returns a failure without tmux writes" do
    source = %{target: "@12", server: :board}

    runner = fn "tmux", args, _ ->
      assert Enum.take(args, 3) == ["-N", "-L", "foreman"]

      cond do
        "list-panes" in args -> {"%464\t@12\twork\tbuild\t1\n", 0}
        "list-clients" in args -> {"", 0}
        true -> flunk("unexpected write")
      end
    end

    assert RequestSource.focus(source, runner: runner) == {:error, :no_client}
  end
end
