defmodule Foreman.SessionsTest do
  use Foreman.DataCase, async: false
  alias Foreman.Sessions

  setup do
    socket = Foreman.TestTmux.socket("fm-sessions")
    dir = Path.join(System.tmp_dir!(), socket)
    File.mkdir_p!(dir)

    {_, 0} =
      System.cmd("tmux", [
        "-L",
        socket,
        "-f",
        "/dev/null",
        "start-server",
        ";",
        "set-option",
        "-g",
        "exit-empty",
        "off"
      ])

    System.cmd("git", ["init", "-q", dir])

    {:ok, config} =
      Foreman.Config.parse_layers([{"defaults", File.read!("priv/foreman.defaults.toml")}])

    config = Map.put(config, "repos", [%{"key" => "sample", "path" => dir, "enabled" => true}])

    Foreman.Repo.insert_all("board_config", [
      %{id: 1, config: config, source: "test", discovered: [], loaded_at: DateTime.utc_now()}
    ])

    rows = [
      %{id: "x-1", title: "Unplanned", issue_type: "task", status: "open"},
      %{id: "x-2", title: "Epic", issue_type: "epic", status: "open"},
      %{
        id: "x-3",
        title: "Child",
        issue_type: "bug",
        status: "open",
        dependencies: [%{depends_on_id: "x-2", type: "parent-child"}]
      }
    ]

    Foreman.Beads.Projection.replace("sample", Enum.map_join(rows, "\n", &Jason.encode!/1))

    on_exit(fn ->
      System.cmd("tmux", ["-L", socket, "kill-server"], stderr_to_stdout: true)
      File.rm_rf!(dir)
    end)

    %{socket: socket, dir: dir, opts: [socket: socket, executable: "/bin/true"]}
  end

  test "idle timeout keeps the record and closes only its window", c do
    assert {:ok, session} = Sessions.launch({"sample", "x-1"}, c.opts)

    System.cmd("tmux", [
      "-L",
      c.socket,
      "set-option",
      "-w",
      "-t",
      session.window,
      "@foreman-state",
      "ended"
    ])

    {other, 0} =
      System.cmd("tmux", [
        "-L",
        c.socket,
        "new-window",
        "-d",
        "-t",
        "sample",
        "-P",
        "-F",
        ~S(#{window_id}),
        "sleep 60"
      ])

    assert :ok = Sessions.reconcile(Keyword.put(c.opts, :idle_timeout, 0))
    parked = Sessions.get({"sample", "x-1"})
    assert parked.state == :parked
    assert parked.session_id == session.session_id

    assert {windows, 0} =
             System.cmd("tmux", ["-L", c.socket, "list-windows", "-a", "-F", ~S(#{window_id})])

    assert windows == other
  end

  test "relaunch opens a new window with the stored conversation id", c do
    assert {:ok, session} = Sessions.launch({"sample", "x-1"}, c.opts)
    System.cmd("tmux", ["-L", c.socket, "kill-window", "-t", session.window])
    Sessions.reconcile(c.opts)
    executable = Path.join(c.dir, "resume-probe")
    File.write!(executable, "#!/bin/sh\nprintf '%s\\n' \"$@\" > resumed-args\n")
    File.chmod!(executable, 0o700)

    assert {:ok, resumed} =
             Sessions.relaunch({"sample", "x-1"}, Keyword.put(c.opts, :executable, executable))

    assert resumed.session_id == session.session_id
    refute resumed.window == session.window
    assert eventually(fn -> File.exists?(Path.join(c.dir, "resumed-args")) end)
    assert ["--resume", id | _] = String.split(File.read!(Path.join(c.dir, "resumed-args")), "\n")
    assert id == session.session_id
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (receive do
         after
           20 -> eventually(fun, attempts - 1)
         end)
  end

  test "hooks refresh inactivity even when they do not change state", c do
    {:ok, session} = Sessions.launch({"sample", "x-1"}, c.opts)
    old = DateTime.add(DateTime.utc_now(), -90_000, :second)
    Foreman.Repo.update!(Ecto.Changeset.change(session, state: :running, last_activity_at: old))

    assert {:ok, active} =
             Sessions.signal({"sample", "x-1"}, session.session_id, :resumed, "activity")

    assert DateTime.compare(active.last_activity_at, old) == :gt
    Sessions.reconcile(c.opts)
    refute Sessions.get({"sample", "x-1"}).state == :parked
  end

  test "viewing the window refreshes inactivity", c do
    {:ok, session} = Sessions.launch({"sample", "x-1"}, c.opts)
    old = DateTime.add(DateTime.utc_now(), -90_000, :second)
    Foreman.Repo.update!(Ecto.Changeset.change(session, last_activity_at: old))

    client =
      Port.open({:spawn_executable, System.find_executable("tmux")}, [
        :binary,
        :exit_status,
        args: ["-L", c.socket, "-C", "attach", "-t", "sample"]
      ])

    assert eventually(fn -> Foreman.SessionTmux.attached?(session, c.opts) == {:ok, true} end)

    assert eventually(fn ->
             Foreman.SessionTmux.observe(session, c.opts) ==
               {:ok, %{window: session.window, state: :ended}}
           end)

    Sessions.reconcile(c.opts)
    current = Sessions.get({"sample", "x-1"})
    refute current.state == :parked
    assert DateTime.compare(current.last_activity_at, old) == :gt
    Port.close(client)
    assert eventually(fn -> Foreman.SessionTmux.attached?(session, c.opts) == {:ok, false} end)
    Sessions.reconcile(c.opts)
    refute Sessions.get({"sample", "x-1"}).state == :parked
  end

  test "the default timeout is one day", c do
    {:ok, session} = Sessions.launch({"sample", "x-1"}, c.opts)

    System.cmd("tmux", [
      "-L",
      c.socket,
      "set-option",
      "-w",
      "-t",
      session.window,
      "@foreman-state",
      "ended"
    ])

    Foreman.Repo.update!(
      Ecto.Changeset.change(session,
        last_activity_at: DateTime.add(DateTime.utc_now(), -86_390, :second)
      )
    )

    Sessions.reconcile(c.opts)
    refute Sessions.get({"sample", "x-1"}).state == :parked

    Foreman.Repo.update!(
      Ecto.Changeset.change(Sessions.get({"sample", "x-1"}),
        last_activity_at: DateTime.add(DateTime.utc_now(), -86_401, :second)
      )
    )

    Sessions.reconcile(c.opts)
    assert Sessions.get({"sample", "x-1"}).state == :parked
  end

  test "relaunch from ended leaves the readable shell open", c do
    {:ok, session} = Sessions.launch({"sample", "x-1"}, c.opts)

    assert eventually(fn ->
             Sessions.reconcile(c.opts)
             Sessions.get({"sample", "x-1"}).state == :ended
           end)

    assert {:ok, resumed} = Sessions.relaunch({"sample", "x-1"}, c.opts)
    refute resumed.window == session.window

    assert {windows, 0} =
             System.cmd("tmux", ["-L", c.socket, "list-windows", "-a", "-F", ~S(#{window_id})])

    assert session.window in String.split(windows)
    assert resumed.window in String.split(windows)

    assert eventually(fn ->
             Foreman.SessionTmux.observe(resumed, c.opts) ==
               {:ok, %{window: resumed.window, state: :ended}}
           end)

    Sessions.reconcile(Keyword.put(c.opts, :idle_timeout, 0))

    assert {"", 0} = System.cmd("tmux", ["-L", c.socket, "list-sessions"])
  end

  test "persists launch identity and reuses its window", c do
    assert {:ok, session} = Sessions.launch({"sample", "x-1"}, c.opts)
    assert session.workdir == c.dir
    assert {:ok, _} = Ecto.UUID.cast(session.session_id)
    assert session.state in [:starting, :running, :ended]
    assert {:ok, again} = Sessions.launch({"sample", "x-1"}, c.opts)
    assert again.session_id == session.session_id
    assert again.window == session.window
    assert Sessions.get({"sample", "x-1"}).session_id == session.session_id
    assert {:error, :not_launchable} = Sessions.launch({"sample", "x-3"}, c.opts)
  end

  test "recovers a window created before the launch response was persisted", c do
    reserved =
      Foreman.Repo.insert!(%Foreman.PlanningSession{
        project: "sample",
        ticket: "x-1",
        state: :starting,
        workdir: c.dir,
        launched_at: DateTime.utc_now()
      })

    assert {:ok, window} = Foreman.SessionTmux.launch(reserved, "flow", c.opts)
    assert {:ok, recovered} = Sessions.launch({"sample", "x-1"}, c.opts)
    assert recovered.session_id == reserved.session_id
    assert recovered.window == window
    System.cmd("tmux", ["-L", c.socket, "kill-window", "-t", window])
    assert :ok = Sessions.reconcile(c.opts)
    assert Sessions.get({"sample", "x-1"}).state == :parked
  end

  test "a manually closed window parks the existing conversation instead of launching another",
       c do
    assert {:ok, session} = Sessions.launch({"sample", "x-1"}, c.opts)
    System.cmd("tmux", ["-L", c.socket, "kill-window", "-t", session.window])
    assert {:error, :session_parked} = Sessions.launch({"sample", "x-1"}, c.opts)
    assert Sessions.get({"sample", "x-1"}).state == :parked
  end

  test "an unresolved parent is not an unplanned ticket" do
    raw = %{
      id: "x-4",
      title: "Missing parent",
      issue_type: "task",
      status: "open",
      dependencies: [%{depends_on_id: "missing", type: "parent-child"}]
    }

    Foreman.Beads.Projection.replace("sample", Jason.encode!(raw))
    refute Sessions.launchable?(Sessions.target({"sample", "x-4"}))
  end

  test "a failed tmux launch retains a retryable identity", c do
    bad = Keyword.put(c.opts, :socket, "missing/path")
    assert {:error, _} = Sessions.launch({"sample", "x-1"}, bad)
    reserved = Sessions.get({"sample", "x-1"})
    assert reserved.state == :starting
    assert reserved.error != nil
    assert {:ok, session} = Sessions.launch({"sample", "x-1"}, c.opts)
    assert session.session_id == reserved.session_id
    assert session.error == nil
  end

  test "preview refuses before recording or contacting tmux", c do
    previous = System.get_env("PREVIEW")
    System.put_env("PREVIEW", "1")

    on_exit(fn ->
      if previous, do: System.put_env("PREVIEW", previous), else: System.delete_env("PREVIEW")
    end)

    assert Sessions.launch({"sample", "x-1"}, c.opts) == {:error, "refused in preview"}
    assert Sessions.get({"sample", "x-1"}) == nil
    assert {"", 0} = System.cmd("tmux", ["-L", c.socket, "list-sessions"], stderr_to_stdout: true)
  end

  test "only unplanned tickets and idea/draft epics can launch" do
    assert Sessions.launchable?(%{type: "task", status: "open", parent: nil})
    assert Sessions.launchable?(%{type: "decision", status: "open", parent: nil})
    assert Sessions.launchable?(%{type: "chore", status: "open", parent: nil})
    assert Sessions.launchable?(%{type: "bug", status: "open", parent: nil})
    assert Sessions.launchable?(%{type: "feature", status: "open", parent: nil})
    refute Sessions.launchable?(%{type: "task", status: "open", parent: "epic"})
    refute Sessions.launchable?(%{type: "task", status: "closed", parent: nil})
    for stage <- [:idea, :draft], do: assert(Sessions.launchable?(%{type: "epic", stage: stage}))

    for stage <- [:speccing, :spec_approved, :ticketed, :done, :abandoned],
        do: refute(Sessions.launchable?(%{type: "epic", stage: stage}))

    refute Sessions.launchable?(nil)
  end
end
