defmodule Foreman.RequestSourceTest do
  use ExUnit.Case, async: false
  alias Foreman.RequestSource

  test "dispatch window and pane targets retain build identity for any caller" do
    request = %{session: "relay-build", actor: "pi"}

    for target <- ["relay-build", "%464"] do
      source =
        RequestSource.resolve(request, [
          %{window: target, details: %{"session" => "relay-build", "harness" => "pi"}}
        ])

      assert source == %{name: "relay-build", harness: "pi", target: target, server: :default}
    end
  end

  test "unnamed legacy dispatches never borrow the request's identity" do
    source =
      RequestSource.resolve(%{session: "build", actor: "pi"}, [
        %{window: "%464", details: %{"harness" => "pi"}}
      ])

    assert source == nil
  end

  test "legacy pane dispatch does not borrow another actor's session" do
    assert RequestSource.resolve(%{session: "coordinator", actor: "claude"}, [
             %{window: "%464", details: %{"harness" => "pi"}}
           ]) == nil
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

  test "old waiting facts are not a substitute for named session resolution" do
    request = %{
      session: "external",
      actor: "pi",
      kind: "session_waiting",
      facts: %{"target" => "external", "pane" => "%464"}
    }

    assert RequestSource.resolve(request, []) == nil
  end

  test "unknown and unrelated sessions do not guess a target" do
    assert RequestSource.resolve(%{session: nil, actor: "pi"}, []) == nil

    assert RequestSource.resolve(%{session: "old", actor: "pi"}, [
             %{window: "%3", details: %{"session" => "new"}}
           ]) == nil
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

  test "board sessions use the board server" do
    source =
      RequestSource.resolve(%{session: "uuid", actor: "claude"}, [], %{
        session_id: "uuid",
        window: "@12",
        ticket: "s-1"
      })

    assert source == %{name: "s-1", harness: "claude", target: "@12", server: :board}
  end
end
