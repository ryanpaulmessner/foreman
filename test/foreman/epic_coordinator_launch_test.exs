defmodule Foreman.EpicCoordinatorLaunchTest do
  use Foreman.DataCase, async: false
  alias Foreman.{AgentSessions, Repo, Sessions}

  setup do
    dir = Path.join(System.tmp_dir!(), "lc-launch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    System.cmd("git", ["init", "-q", dir])
    executable = Path.join(dir, "claude")

    File.write!(
      executable,
      "#!/bin/sh\nprintf '%s\\n' \"$@\" > argv\nprintf '%s' \"$FOREMAN_SESSION\" > identity\nexec sleep 120\n"
    )

    File.chmod!(executable, 0o700)
    socket = Foreman.TestTmux.socket("lc-scratch")

    System.cmd(
      "tmux",
      [
        "-L",
        socket,
        "-f",
        "/dev/null",
        "new-session",
        "-d",
        "-s",
        "sample",
        "-n",
        "keeper",
        "sleep 120"
      ],
      env: [{"SHELL", "/bin/sh"}]
    )

    System.cmd("tmux", ["-L", socket, "set-option", "-g", "default-shell", "/bin/sh"])

    {:ok, config} =
      Foreman.Config.parse_layers([{"defaults", File.read!("priv/foreman.defaults.toml")}])

    Repo.insert_all("board_config", [
      %{
        id: 1,
        config:
          Map.put(config, "repos", [%{"key" => "sample", "path" => dir, "enabled" => true}]),
        source: "test",
        discovered: [],
        loaded_at: DateTime.utc_now()
      }
    ])

    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "lc-1", title: "Launch", issue_type: "epic", status: "open"})
    )

    on_exit(fn ->
      System.cmd("tmux", ["-L", socket, "kill-server"], stderr_to_stdout: true)
      File.rm_rf!(dir)
    end)

    %{dir: dir, socket: socket, opts: [socket: socket, executable: executable]}
  end

  test "ticketed launch uses the main model, scoped prompt and its own identity", c do
    {:ok, main} =
      AgentSessions.create(%{
        name: "main",
        kind: "main_coordinator",
        harness: "claude",
        model: "opus",
        tmux_server: "default"
      })

    {:ok, newer} =
      AgentSessions.create(%{
        name: "newer-ended",
        kind: "main_coordinator",
        harness: "claude",
        model: "wrong",
        tmux_server: "default"
      })

    AgentSessions.end_session(newer)
    assert {:ok, planning} = Sessions.launch({"sample", "lc-1"}, c.opts)
    assert eventually(fn -> File.exists?(Path.join(c.dir, "identity")) end)
    args = File.read!(Path.join(c.dir, "argv"))
    assert args =~ "--model\nopus\n"
    assert args =~ "dispatch"
    assert args =~ "pane mode"
    refute args =~ "/tight-spec"
    assert File.read!(Path.join(c.dir, "identity")) == "lc-1"
    row = AgentSessions.get(planning.agent_session_id)
    assert row.kind == "epic_coordinator"
    assert row.parent_id == main.id
    assert row.model == "opus"
    assert row.workdir == c.dir
    assert row.conversation_id == planning.session_id
    assert row.pane_id =~ ~r/^%\d+$/

    assert {"lc-1\n", 0} =
             System.cmd("tmux", [
               "-L",
               c.socket,
               "display-message",
               "-p",
               "-t",
               planning.window,
               "\#{window_name}"
             ])

    System.cmd("tmux", ~w(-L #{c.socket} select-window -t sample:keeper))
    assert {:ok, again} = Sessions.launch({"sample", "lc-1"}, c.opts)

    assert {"1\n", 0} =
             System.cmd("tmux", [
               "-L",
               c.socket,
               "display-message",
               "-p",
               "-t",
               planning.window,
               "\#{window_active}"
             ])

    assert again.session_id == planning.session_id
    assert again.window == planning.window

    assert {windows, 0} =
             System.cmd("tmux", [
               "-L",
               c.socket,
               "list-windows",
               "-t",
               "sample",
               "-F",
               "\#{window_name}"
             ])

    assert Enum.count(String.split(windows), &(&1 == "lc-1")) == 1
  end

  test "a live registered coordinator is focused without creating a planning row", c do
    old = Application.get_env(:foreman, :external_tmux_socket)
    Application.put_env(:foreman, :external_tmux_socket, c.socket)

    on_exit(fn ->
      if old,
        do: Application.put_env(:foreman, :external_tmux_socket, old),
        else: Application.delete_env(:foreman, :external_tmux_socket)
    end)

    {pane, 0} =
      System.cmd("tmux", [
        "-L",
        c.socket,
        "display-message",
        "-p",
        "-t",
        "sample:keeper",
        "\#{pane_id}"
      ])

    {:ok, row} =
      AgentSessions.create(%{
        name: "lc-1",
        kind: "epic_coordinator",
        harness: "claude",
        tmux_server: "default",
        pane_id: String.trim(pane)
      })

    assert {:ok, :no_client} = Sessions.launch({"sample", "lc-1"}, c.opts)
    assert is_nil(Sessions.get({"sample", "lc-1"}))
    assert is_nil(AgentSessions.get(row.id).ended_at)
  end

  test "without a main coordinator the row is unassigned and no model flag is passed", c do
    assert {:ok, planning} = Sessions.launch({"sample", "lc-1"}, c.opts)
    assert eventually(fn -> File.exists?(Path.join(c.dir, "identity")) end)
    refute File.read!(Path.join(c.dir, "argv")) =~ "--model"
    row = AgentSessions.get(planning.agent_session_id)
    assert is_nil(row.parent_id)
    assert is_nil(row.model)
  end

  test "the most recent ended main is the parent when none is live", c do
    {:ok, older} =
      AgentSessions.create(%{
        name: "older",
        kind: "main_coordinator",
        harness: "claude",
        tmux_server: "default",
        model: "old",
        started_at: DateTime.add(DateTime.utc_now(), -3600)
      })

    AgentSessions.end_session(older)

    {:ok, recent} =
      AgentSessions.create(%{
        name: "recent",
        kind: "main_coordinator",
        harness: "claude",
        tmux_server: "default"
      })

    AgentSessions.end_session(recent)
    assert {:ok, planning} = Sessions.launch({"sample", "lc-1"}, c.opts)
    assert AgentSessions.get(planning.agent_session_id).parent_id == recent.id
    assert eventually(fn -> File.exists?(Path.join(c.dir, "identity")) end)
    refute File.read!(Path.join(c.dir, "argv")) =~ "--model"
  end

  for stage <- ["idea", "speccing", "spec_approved"] do
    test "#{stage} keeps the tight-spec prompt", c do
      Repo.update_all("epics", set: [stage: unquote(stage)])
      assert {:ok, _} = Sessions.launch({"sample", "lc-1"}, c.opts)
      assert eventually(fn -> File.exists?(Path.join(c.dir, "identity")) end)
      assert File.read!(Path.join(c.dir, "argv")) =~ "/tight-spec"
    end
  end

  test "a launcher crash leaves the reserved conversation available for retry", c do
    runner = fn _command, args, _opts ->
      if "list-windows" in args, do: {"", 0}, else: raise("launcher crashed")
    end

    assert_raise RuntimeError, "launcher crashed", fn ->
      Sessions.launch({"sample", "lc-1"}, Keyword.put(c.opts, :runner, runner))
    end

    reserved = Sessions.get({"sample", "lc-1"})
    assert reserved.state == :starting
    assert AgentSessions.get(reserved.agent_session_id).conversation_id == reserved.session_id
    assert {:ok, retried} = Sessions.launch({"sample", "lc-1"}, c.opts)
    assert retried.session_id == reserved.session_id
  end

  test "a live name owned by another project is never replaced", c do
    {:ok, row} =
      AgentSessions.create(%{
        name: "lc-1",
        kind: "epic_coordinator",
        harness: "claude",
        tmux_server: "default",
        project: "other",
        ticket: "lc-1"
      })

    assert {:error, :session_name_taken} = Sessions.launch({"sample", "lc-1"}, c.opts)
    assert is_nil(Sessions.get({"sample", "lc-1"}))
    assert is_nil(AgentSessions.get(row.id).ended_at)
  end

  test "Resume preserves the conversation, model and identity with a new pane", c do
    {:ok, _} =
      AgentSessions.create(%{
        name: "main",
        kind: "main_coordinator",
        harness: "claude",
        model: "opus",
        tmux_server: "default"
      })

    {:ok, planning} = Sessions.launch({"sample", "lc-1"}, c.opts)
    assert eventually(fn -> File.exists?(Path.join(c.dir, "identity")) end)
    previous = AgentSessions.get(planning.agent_session_id)
    System.cmd("tmux", ["-L", c.socket, "kill-window", "-t", planning.window])
    File.rm!(Path.join(c.dir, "identity"))
    assert {:ok, resumed} = Sessions.relaunch({"sample", "lc-1"}, c.opts)
    assert eventually(fn -> File.exists?(Path.join(c.dir, "identity")) end)
    args = File.read!(Path.join(c.dir, "argv"))
    assert args =~ "--resume\n#{planning.session_id}\n"
    assert args =~ "--model\nopus\n"
    refute args =~ "--session-id"
    row = AgentSessions.get(resumed.agent_session_id)
    assert row.id == previous.id
    assert row.pane_id != previous.pane_id
    assert is_nil(row.ended_at)
  end

  test "the session page's Resume and R8 relaunch note go through the planning session", c do
    {:ok, _} =
      AgentSessions.create(%{
        name: "main",
        kind: "main_coordinator",
        harness: "claude",
        model: "opus",
        tmux_server: "default"
      })

    {:ok, planning} = Sessions.launch({"sample", "lc-1"}, c.opts)
    assert eventually(fn -> File.exists?(Path.join(c.dir, "identity")) end)
    coordinator = AgentSessions.get(planning.agent_session_id)
    {:ok, coordinator, _} = AgentSessions.fire(coordinator, :stop)
    System.cmd("tmux", ["-L", c.socket, "kill-window", "-t", planning.window])
    File.rm!(Path.join(c.dir, "identity"))

    {:ok, build} =
      AgentSessions.create(%{
        name: "lc-build",
        kind: "build",
        harness: "pi",
        parent_id: coordinator.id,
        tmux_server: "default",
        ticket: "lc-2",
        branch: "feat/lc-2"
      })

    build = AgentSessions.end_session(build)

    assert {:ok, %{coordinator: "lc-1", resumed: true}} =
             Foreman.SessionResume.relaunch_build(build, c.opts)

    assert eventually(fn -> File.exists?(Path.join(c.dir, "identity")) end)
    args = File.read!(Path.join(c.dir, "argv"))
    assert args =~ "--resume\n#{planning.session_id}\n"
    assert args =~ "[foreman note from board] Relaunch the build for lc-2 on feat/lc-2.\n"
    refute args =~ "/orient"
    row = AgentSessions.get(coordinator.id)
    assert is_nil(row.ended_at)
    assert row.pane_id != coordinator.pane_id
  end

  test "a configured worktree launches in the main checkout", c do
    linked = Path.join(c.dir, "linked")

    assert {_, 0} =
             System.cmd(
               "git",
               ["-C", c.dir, "worktree", "add", "--orphan", "-b", "linked", linked],
               stderr_to_stdout: true
             )

    Repo.query!(
      "UPDATE board_config SET config = jsonb_set(config, '{repos,0,path}', to_jsonb($1::text))",
      [linked]
    )

    assert {:ok, planning} = Sessions.launch({"sample", "lc-1"}, c.opts)
    assert planning.workdir == c.dir
    assert eventually(fn -> File.exists?(Path.join(c.dir, "identity")) end)
    refute File.exists?(Path.join(linked, "identity"))
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
end
