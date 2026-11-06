defmodule Foreman.GridCaptureTest do
  use ExUnit.Case, async: true
  alias Foreman.PaneCapture

  test "one client splits eleven distinct panes and isolates a missing pane" do
    socket = "sg-test-#{System.unique_integer([:positive])}"
    tmux = System.find_executable("tmux")
    on_exit(fn -> System.cmd(tmux, ["-L", socket, "kill-server"]) end)

    for n <- 1..11 do
      command = "printf 'pane-#{n}\\n'; '#{tmux}' -L '#{socket}' wait-for -S ready-#{n}; sleep 60"

      args =
        if n == 1,
          do: ["new-session", "-d", "-s", "test", command],
          else: ["new-window", "-t", "test", command]

      {_, 0} = System.cmd(tmux, ["-f", "/dev/null", "-L", socket | args])
      {_, 0} = System.cmd(tmux, ["-L", socket, "wait-for", "ready-#{n}"])
    end

    owner = self()

    runner = fn cmd, args, opts ->
      send(owner, {:call, args})
      System.cmd(cmd, args, opts)
    end

    targets = for n <- 1..11, do: %{id: n, socket: socket, target: "%#{n - 1}"}
    targets = List.insert_at(targets, 5, %{id: :missing, socket: socket, target: "%999999"})
    result = PaneCapture.read_batch(targets, runner: runner)
    assert result.missing == {:error, :tmux_unavailable}

    for n <- 1..11 do
      assert {:ok, text} = result[n]
      assert String.trim(text) == "pane-#{n}"
    end

    assert_receive {:call, args}
    assert "-N" in args
    assert "-F" in args
    refute_receive {:call, _}
  end

  test "empty targets do not start a client" do
    assert PaneCapture.read_batch([], runner: fn _, _, _ -> flunk("unexpected tmux") end) == %{}
  end

  test "distinct sockets get one client each" do
    owner = self()

    runner = fn _, ["-N", "-L", socket | _], _ ->
      send(owner, {:socket, socket})
      {"no server", 1}
    end

    targets = [
      %{id: 1, socket: "sg-a", target: "%0"},
      %{id: 2, socket: "sg-a", target: "%1"},
      %{id: 3, socket: "sg-b", target: "%0"}
    ]

    assert PaneCapture.read_batch(targets, runner: runner) == %{
             1 => {:error, :tmux_unavailable},
             2 => {:error, :tmux_unavailable},
             3 => {:error, :tmux_unavailable}
           }

    assert_receive {:socket, "sg-a"}
    assert_receive {:socket, "sg-b"}
    refute_receive {:socket, _}
  end
end
