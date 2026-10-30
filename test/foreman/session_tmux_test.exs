defmodule Foreman.SessionTmuxTest do
  use ExUnit.Case, async: true
  alias Foreman.SessionTmux, as: Tmux

  setup do
    socket = Foreman.TestTmux.socket("fm-test")
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

    executable = Path.join(dir, "claude-probe")
    File.write!(executable, "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\" > args\nread line\n")
    File.chmod!(executable, 0o700)

    on_exit(fn ->
      System.cmd("tmux", ["-L", socket, "kill-server"], stderr_to_stdout: true)
      File.rm_rf!(dir)
    end)

    %{
      socket: socket,
      dir: dir,
      opts: [socket: socket, executable: executable],
      session: %{
        project: "sample",
        ticket: "x-1.2",
        session_id: Ecto.UUID.generate(),
        workdir: dir
      }
    }
  end

  test "creates project and ticket window, preserves argv, and focuses instead of duplicating",
       c do
    prompt = "flow: user's `touch BAD` $(touch BAD)\nquoted \"value\"; end"
    assert {:ok, window} = Tmux.launch(c.session, prompt, c.opts)
    assert String.starts_with?(window, "@")
    assert {:ok, ^window} = Tmux.launch(c.session, "ignored", c.opts)

    assert {"sample:x-1.2\n", 0} =
             System.cmd("tmux", [
               "-L",
               c.socket,
               "list-windows",
               "-a",
               "-F",
               ~S(#{session_name}:#{window_name})
             ])

    System.cmd("tmux", ["-L", c.socket, "send-keys", "-t", window, "Enter"])
    assert eventually(fn -> File.exists?(Path.join(c.dir, "args")) end)

    assert File.read!(Path.join(c.dir, "args")) ==
             "#{c.dir}\n--session-id\n#{c.session.session_id}\n--settings\n#{Jason.encode!(Foreman.SessionHooks.settings(c.session, c.opts))}\n#{prompt}\n"

    refute File.exists?(Path.join(c.dir, "BAD"))

    assert eventually(fn ->
             Tmux.observe(c.session, c.opts) == {:ok, %{window: window, state: :ended}}
           end)

    assert {_, 0} = System.cmd("tmux", ["-L", c.socket, "has-session", "-t", "=sample"])
  end

  test "focus switches a scratch client from its own session to coordinator and ticket", c do
    {_, 0} = System.cmd("tmux", ["-L", c.socket, "new-session", "-d", "-s", "viewer"])

    client =
      Port.open({:spawn_executable, System.find_executable("tmux")}, [
        :binary,
        :exit_status,
        args: ["-L", c.socket, "-C", "attach", "-t", "viewer"]
      ])

    on_exit(fn -> if Port.info(client), do: Port.close(client) end)

    assert eventually(fn ->
             {output, 0} =
               System.cmd("tmux", ["-L", c.socket, "list-clients", "-F", "\#{session_name}"])

             String.trim(output) == "viewer"
           end)

    for {project, ticket, expected} <- [
          {"__foreman__", "coordinator", "coordinator"},
          {"sample", "x-1.2", "sample"}
        ] do
      session = %{c.session | project: project, ticket: ticket}
      {:ok, window} = Tmux.launch(session, "flow", c.opts)

      assert :ok =
               Tmux.focus(
                 Map.put(session, :window, window),
                 Keyword.put(c.opts, :platform, {:unix, :linux})
               )

      assert {output, 0} =
               System.cmd("tmux", [
                 "-L",
                 c.socket,
                 "list-clients",
                 "-F",
                 "\#{session_name}:\#{window_id}"
               ])

      assert String.trim(output) == expected <> ":" <> window
    end

    Port.close(client)
  end

  test "focus with no attached scratch client succeeds with an attach result", c do
    {:ok, window} = Tmux.launch(c.session, "flow", c.opts)
    assert {:ok, :no_client} = Tmux.focus(Map.put(c.session, :window, window), c.opts)
  end

  test "parking refuses attached clients and foreign identities", c do
    assert {:ok, window} = Tmux.launch(c.session, "flow", c.opts)
    session = Map.put(c.session, :window, window)

    assert eventually(fn ->
             Tmux.observe(session, c.opts) == {:ok, %{window: window, state: :running}}
           end)

    client =
      Port.open({:spawn_executable, System.find_executable("tmux")}, [
        :binary,
        :exit_status,
        args: ["-L", c.socket, "-C", "attach", "-t", "sample"]
      ])

    assert eventually(fn -> Tmux.attached?(session, c.opts) == {:ok, true} end)
    assert {:error, :parking_refused} = Tmux.park(session, c.opts)
    assert {:ok, %{window: ^window}} = Tmux.observe(session, c.opts)
    Port.close(client)
    assert eventually(fn -> Tmux.attached?(session, c.opts) == {:ok, false} end)

    assert {:error, :parking_refused} =
             Tmux.park(%{session | session_id: Ecto.UUID.generate()}, c.opts)

    assert :ok = Tmux.park(session, c.opts)
    assert {:ok, :window_gone} = Tmux.observe(session, c.opts)
  end

  test "attach addresses the recorded window even when ticket names repeat", c do
    session = Map.put(c.session, :window, "@42")
    assert Tmux.attach_command(session, c.opts) == "tmux attach -t 'sample:@42'"
  end

  test "an unmarked window cannot be mistaken for the stored conversation", c do
    assert {:ok, window} = Tmux.launch(c.session, "flow", c.opts)
    session = Map.put(c.session, :window, window)

    assert eventually(fn ->
             Tmux.observe(session, c.opts) == {:ok, %{window: window, state: :running}}
           end)

    System.cmd("tmux", ["-L", c.socket, "set-option", "-wu", "-t", window, "@foreman-session"])
    assert {:ok, :window_gone} = Tmux.observe(session, c.opts)
    assert {:error, :parking_refused} = Tmux.park(session, c.opts)
  end

  test "Continue sends only the literal word and Enter to the identified planning window", c do
    executable = Path.join(c.dir, "receiver")

    File.write!(
      executable,
      "#!/bin/sh\nprintf ready > ready\nIFS= read -r line\nprintf '%s' \"$line\" > received\nread more\n"
    )

    File.chmod!(executable, 0o700)
    opts = Keyword.put(c.opts, :executable, executable)
    assert {:ok, window} = Tmux.launch(c.session, "flow", opts)
    assert eventually(fn -> File.exists?(Path.join(c.dir, "ready")) end)
    refute File.exists?(Path.join(c.dir, "received"))
    assert :ok = Tmux.continue_session(Map.put(c.session, :window, window), opts)
    assert eventually(fn -> File.exists?(Path.join(c.dir, "received")) end)
    assert File.read!(Path.join(c.dir, "received")) == "continue"

    assert {:error, _} =
             Tmux.continue_session(
               c.session
               |> Map.put(:window, window)
               |> Map.put(:session_id, Ecto.UUID.generate()),
               opts
             )
  end

  test "coordinator windows resolve exactly on the external socket", c do
    assert {:ok, window} = Tmux.launch(c.session, "flow", c.opts)
    assert {:ok, facts} = Tmux.external_target("x-1.2", c.opts)
    assert facts["window"] == window
    assert facts["target"] == "external"
    assert facts["attach"] =~ "tmux attach"
    assert {:error, _} = Tmux.external_target("x-1", c.opts)
    assert {:error, _} = Tmux.external_target("; send-keys bad", c.opts)
  end

  test "new tickets get separate windows without replacing existing ones", c do
    assert {:ok, first} = Tmux.launch(c.session, "flow", c.opts)

    assert {:ok, second} =
             Tmux.launch(
               %{c.session | ticket: "x-2", session_id: Ecto.UUID.generate()},
               "flow",
               c.opts
             )

    refute first == second
    assert {:ok, ^first} = Tmux.launch(c.session, "flow", c.opts)

    assert {selected, 0} =
             System.cmd("tmux", [
               "-L",
               c.socket,
               "list-windows",
               "-t",
               "=sample",
               "-F",
               ~S(#{?window_active,#{window_id},})
             ])

    assert String.trim(selected) == first

    assert eventually(fn ->
             Tmux.observe(c.session, c.opts) == {:ok, %{window: first, state: :running}}
           end)
  end

  test "service variables introduced by login startup are removed before Claude", c do
    shell = Path.join(c.dir, "login-shell")

    File.write!(
      shell,
      "#!/bin/sh\nif [ \"$1\" = -ilc ]; then\nexport RELEASE_LOGIN_ONLY=test PHX_LOGIN_ONLY=test\nexec /bin/sh -c \"$2\"\nfi\n"
    )

    File.chmod!(shell, 0o700)
    executable = Path.join(c.dir, "env-probe")

    File.write!(
      executable,
      "#!/bin/sh\nprintf '%s:%s' \"${RELEASE_LOGIN_ONLY-unset}\" \"${PHX_LOGIN_ONLY-unset}\" > '#{c.dir}/login-env'\n"
    )

    File.chmod!(executable, 0o700)

    {:ok, command} =
      Tmux.coordinator_wrapper(c.session, :fresh, Keyword.put(c.opts, :executable, executable))

    System.cmd("/bin/sh", ["-c", command], env: [{"SHELL", shell}], stderr_to_stdout: true)
    assert File.read!(Path.join(c.dir, "login-env")) == "unset:unset"
  end

  test "coordinator tmux failure returns a serializable refusal", c do
    assert {:error, :tmux_unavailable} =
             Tmux.respawn_coordinator(
               Map.put(c.session, :window, "@9999"),
               :fresh,
               "%9999",
               c.opts
             )
  end

  test "coordinator refuses an unavailable working directory accurately", c do
    assert {:error, :invalid_launch_target} =
             Tmux.coordinator_wrapper(
               %{c.session | workdir: Path.join(c.dir, "missing")},
               :fresh,
               c.opts
             )
  end

  test "a missing Claude executable refuses without opening a window", c do
    assert {:error, :claude_unavailable} =
             Tmux.launch(
               c.session,
               "flow",
               Keyword.put(c.opts, :executable, "/nonexistent/claude")
             )

    assert {"", 0} = System.cmd("tmux", ["-L", c.socket, "list-sessions"])
  end

  test "does not start a server inside the calling app's process group", c do
    System.cmd("tmux", ["-L", c.socket, "kill-server"])
    assert {:error, _} = Tmux.launch(c.session, "flow", c.opts)

    assert {_, 1} =
             System.cmd("tmux", ["-N", "-L", c.socket, "list-sessions"], stderr_to_stdout: true)
  end

  test "manually renamed windows cannot crash liveness polling", c do
    assert {:ok, window} = Tmux.launch(c.session, "flow", c.opts)
    System.cmd("tmux", ["-L", c.socket, "rename-window", "-t", window, "odd\tname"])
    assert {:ok, :window_gone} = Tmux.observe(c.session, c.opts)
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
