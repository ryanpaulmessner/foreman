defmodule Foreman.IdleParkTest do
  use Foreman.DataCase, async: false

  alias Foreman.{AgentSessions, PlanningSession, Repo, Sessions, SessionTmux}

  setup do
    socket = Foreman.TestTmux.socket("fm-idle-park")
    dir = Path.join(System.tmp_dir!(), socket)
    File.mkdir_p!(dir)
    id = Ecto.UUID.generate()

    on_exit(fn ->
      System.cmd("tmux", ["-L", socket, "kill-server"], stderr_to_stdout: true)
      File.rm_rf!(dir)
    end)

    {output, 0} =
      System.cmd("tmux", [
        "-L",
        socket,
        "-f",
        "/dev/null",
        "new-session",
        "-d",
        "-s",
        "sample",
        "-n",
        "epic",
        "-c",
        dir,
        "-P",
        "-F",
        ~S(#{window_id} #{pane_id}),
        "sleep 120"
      ])

    [window, pane] = String.split(output)

    {_, 0} =
      System.cmd("tmux", ["-L", socket, "set-option", "-w", "-t", window, "@foreman-session", id])

    {_, 0} =
      System.cmd("tmux", [
        "-L",
        socket,
        "set-option",
        "-w",
        "-t",
        window,
        "@foreman-state",
        "running"
      ])

    {build, 0} =
      System.cmd("tmux", [
        "-L",
        socket,
        "split-window",
        "-t",
        pane,
        "-c",
        dir,
        "-P",
        "-F",
        ~S(#{pane_id}),
        "sleep 120"
      ])

    now = DateTime.utc_now()

    planning =
      Repo.insert!(%PlanningSession{
        project: "sample",
        ticket: "epic",
        session_id: id,
        window: window,
        workdir: dir,
        state: :running,
        launched_at: now,
        last_activity_at: now
      })

    row = AgentSessions.sync_planning(planning, pane: pane)

    build_row =
      AgentSessions.register(%{
        "name" => "pane-build",
        "pane" => String.trim(build),
        "parent" => row.name,
        "harness" => "pi",
        "workdir" => dir
      })

    %{
      socket: socket,
      planning: planning,
      row: row,
      build_row: build_row,
      pane: pane,
      build: String.trim(build),
      opts: [socket: socket, idle_timeout: 0]
    }
  end

  test "idle timeout closes only the coordinator pane and parks both rows", c do
    assert :ok = Sessions.reconcile(c.opts)

    assert {panes, 0} =
             System.cmd("tmux", [
               "-L",
               c.socket,
               "list-panes",
               "-a",
               "-F",
               ~S(#{pane_id} #{pane_dead} #{@foreman-session})
             ])

    assert String.trim(panes) == c.build <> " 0"
    assert Sessions.get({"sample", "epic"}).state == :parked
    assert AgentSessions.get(c.row.id).state == "parked"
    assert AgentSessions.get(c.row.id).ended_at
    assert %{ended_at: nil, parent_id: parent_id} = AgentSessions.get(c.build_row.id)
    assert parent_id == c.row.id
    assert :ok = Sessions.reconcile(c.opts)
    assert AgentSessions.get(c.row.id).state == "parked"
  end

  test "an attached client prevents idle parking even with a build active", c do
    client =
      Port.open({:spawn_executable, System.find_executable("tmux")}, [
        :binary,
        :exit_status,
        args: ["-L", c.socket, "-C", "attach", "-t", "sample"]
      ])

    on_exit(fn -> if Port.info(client), do: Port.close(client) end)
    await_attached(c, 100)
    assert :ok = Sessions.reconcile(c.opts)

    assert {:error, :parking_refused} =
             SessionTmux.park(c.planning, Keyword.put(c.opts, :pane, c.pane))

    assert {panes, 0} =
             System.cmd("tmux", ["-L", c.socket, "list-panes", "-a", "-F", ~S(#{pane_id})])

    assert Enum.sort(String.split(panes)) == Enum.sort([c.pane, c.build])
    assert Sessions.get({"sample", "epic"}).state == :running
    refute AgentSessions.get(c.row.id).ended_at
  end

  test "a shared window without a recorded coordinator pane is refused", c do
    assert {:error, :parking_refused} = SessionTmux.park(c.planning, c.opts)
    assert {:ok, %{window: window}} = SessionTmux.observe(c.planning, c.opts)
    assert window == c.planning.window
  end

  test "a stale coordinator pane never falls back to the active build", c do
    opts = Keyword.put(c.opts, :pane, "%999999")
    assert {:error, :parking_refused} = SessionTmux.park(c.planning, opts)
    assert {:ok, %{window: window}} = SessionTmux.observe(c.planning, c.opts)
    assert window == c.planning.window
  end

  test "a changed window identity refuses the pane close", c do
    foreign = %{c.planning | session_id: Ecto.UUID.generate()}

    assert {:error, :parking_refused} =
             SessionTmux.park(foreign, Keyword.put(c.opts, :pane, c.pane))

    assert {:ok, %{window: window}} = SessionTmux.observe(c.planning, c.opts)
    assert window == c.planning.window
  end

  defp await_attached(_, 0), do: flunk("scratch client did not attach")

  defp await_attached(c, tries) do
    if SessionTmux.attached?(c.planning, c.opts) != {:ok, true} do
      receive do
      after
        10 -> await_attached(c, tries - 1)
      end
    end
  end
end
