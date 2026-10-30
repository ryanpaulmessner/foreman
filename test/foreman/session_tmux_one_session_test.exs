defmodule Foreman.SessionTmuxOneSessionTest do
  use ExUnit.Case, async: false
  alias Foreman.SessionTmux, as: Tmux

  setup do
    socket = Foreman.TestTmux.socket("fm-one")
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
    File.write!(executable, "#!/bin/sh\nread line\n")
    File.chmod!(executable, 0o700)
    Application.put_env(:foreman, :tmux_session, "coordinator")

    on_exit(fn ->
      Application.delete_env(:foreman, :tmux_session)
      System.cmd("tmux", ["-L", socket, "kill-server"], stderr_to_stdout: true)
      File.rm_rf!(dir)
    end)

    %{socket: socket, dir: dir, opts: [socket: socket, executable: executable]}
  end

  test "with board.tmux_session set, launches from every project open as windows of that one tmux session",
       c do
    work = %{
      project: "work",
      ticket: "draft:system-health",
      session_id: Ecto.UUID.generate(),
      workdir: c.dir
    }

    other = %{project: "skills", ticket: "sk-1", session_id: Ecto.UUID.generate(), workdir: c.dir}

    assert {:ok, first} = Tmux.launch(work, "flow", c.opts)
    assert {:ok, second} = Tmux.launch(other, "flow", c.opts)
    refute first == second

    assert {out, 0} =
             System.cmd("tmux", [
               "-L",
               c.socket,
               "list-windows",
               "-a",
               "-F",
               ~S(#{session_name}:#{window_name})
             ])

    assert out |> String.split("\n", trim: true) |> Enum.sort() ==
             ["coordinator:draft:system-health", "coordinator:sk-1"]

    assert {:ok, %{window: ^first}} = Tmux.observe(work, c.opts)
    assert {:ok, ^first} = Tmux.launch(work, "ignored", c.opts)
  end
end
