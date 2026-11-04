defmodule Foreman.SessionOutputObserverTest do
  @moduledoc """
  The monitor tick on a scratch tmux server: working and idle come from the one pane
  listing, with an injected clock, a tmux command log, and no `capture-pane`.
  """
  use Foreman.DataCase, async: false
  alias Foreman.AgentSessions

  @t0 ~U[2026-11-04 12:00:00.000000Z]

  setup do
    socket = Foreman.TestTmux.socket("fm-lc")
    parent = self()

    runner = fn cmd, args, opts ->
      send(parent, {:tmux, args})
      System.cmd(cmd, args, opts)
    end

    %{socket: socket, runner: runner}
  end

  defp tmux(c, args) do
    {out, 0} = System.cmd("tmux", ["-L", c.socket, "-f", "/dev/null" | args])
    String.trim(out)
  end

  defp register(name, pane) do
    {:ok, %{id: id}} =
      Foreman.SessionRegistry.register(%{
        "name" => name,
        "pane" => pane,
        "workdir" => "/tmp",
        "harness" => "pi"
      })

    id
  end

  # One monitor tick (`Foreman.SessionMonitor` runs `Sessions.reconcile/1`) at `at`.
  defp tick(c, at) do
    :ok = Foreman.Sessions.reconcile(runner: c.runner, socket: c.socket, now: at)
    calls(c)
  end

  defp calls(c, acc \\ []) do
    receive do
      {:tmux, ["-N", "-L", socket | args]} when socket == c.socket -> calls(c, [args | acc])
      {:tmux, args} -> calls(c, [args | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp state(id), do: AgentSessions.get(id).state

  defp next_second(seen) do
    if System.os_time(:second) <= seen do
      receive do
      after
        50 -> next_second(seen)
      end
    end
  end

  defp changed_from(c, target, format, before), do: wait_change(c, target, format, before, 100)

  # Waits (outside the logged runner) until tmux reports a new value for `format`.
  defp changed(c, target, format, attempts \\ 100) do
    before = tmux(c, ["display-message", "-p", "-t", target, format])
    wait_change(c, target, format, before, attempts)
  end

  defp wait_change(_c, _target, _format, _before, 0), do: flunk("tmux output did not change")

  defp wait_change(c, target, format, before, attempts) do
    if tmux(c, ["display-message", "-p", "-t", target, format]) == before do
      receive do
      after
        50 -> wait_change(c, target, format, before, attempts - 1)
      end
    else
      :ok
    end
  end

  defp assert_one_listing(calls) do
    assert [["list-panes", "-a", "-F", _]] = calls
    refute Enum.any?(calls, &("capture-pane" in &1))
  end

  test "a quiet pane goes working -> idle after 2 min with one list-panes per tick", c do
    pane =
      tmux(c, [
        "new-session",
        "-d",
        "-P",
        "-F",
        ~S(#{pane_id}),
        "sh -c 'echo started; read line; echo $line; exec sleep 600'"
      ])

    id = register("b1", pane)
    assert state(id) == "starting"

    assert_one_listing(tick(c, @t0))
    assert state(id) == "working"

    assert_one_listing(tick(c, DateTime.add(@t0, 60)))
    assert state(id) == "working"

    assert_one_listing(tick(c, DateTime.add(@t0, 121)))
    row = AgentSessions.get(id)
    assert row.state == "idle"
    # Idle since the output stopped, so "for <time>" counts from then.
    assert row.state_at == @t0

    # Output again: idle -> working on the next tick. tmux's activity time counts
    # seconds, so the new output must land in a later second than the first.
    seen =
      String.to_integer(tmux(c, ["display-message", "-p", "-t", pane, ~S(#{window_activity})]))

    next_second(seen)
    tmux(c, ["send-keys", "-t", pane, "again", "Enter"])
    changed_from(c, pane, ~S(#{window_activity}), Integer.to_string(seen))
    assert_one_listing(tick(c, DateTime.add(@t0, 130)))
    assert state(id) == "working"
  end

  test "a pane build stays quiet while another pane in its window prints", c do
    window =
      tmux(c, ["new-session", "-d", "-P", "-F", ~S(#{window_id}), "exec sleep 600"])

    build =
      tmux(c, [
        "split-window",
        "-t",
        window,
        "-P",
        "-F",
        ~S(#{pane_id}),
        "sh -c 'echo build; exec sleep 600'"
      ])

    talker =
      tmux(c, [
        "split-window",
        "-t",
        window,
        "-P",
        "-F",
        ~S(#{pane_id}),
        "sh -c 'while true; do echo tick; sleep 0.2; done'"
      ])

    id = register("b1", build)
    talker_id = register("coord", talker)

    assert_one_listing(tick(c, @t0))
    assert state(id) == "working"

    changed(c, talker, ~S(#{history_size}))
    assert_one_listing(tick(c, DateTime.add(@t0, 121)))
    assert state(id) == "idle"
    assert state(talker_id) == "working"
  end

  test "a pane that closes ends its row on the next tick", c do
    pane =
      tmux(c, ["new-session", "-d", "-P", "-F", ~S(#{pane_id}), "exec sleep 600"])

    tmux(c, ["new-window", "-d", "exec sleep 600"])
    id = register("b1", pane)
    assert_one_listing(tick(c, @t0))

    tmux(c, ["kill-pane", "-t", pane])
    assert_one_listing(tick(c, DateTime.add(@t0, 3)))
    assert %{state: "ended", ended_at: %DateTime{}} = AgentSessions.get(id)
  end
end
