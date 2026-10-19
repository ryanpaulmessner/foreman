defmodule Foreman.ScratchPrompt do
  @moduledoc """
  A stand-in for Claude's AskUserQuestion prompt in a board-launched window on a
  scratch tmux server. Every keystroke byte is appended to `received`; the digits 1
  and 2 answer (the screen then shows only "answered"), 3 moves the pointer to
  the free-text row.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]
  alias Foreman.Repo

  @question %{
    "question" => "Which database?",
    "options" => ["Postgres", "SQLite"],
    "multi" => false
  }

  def question, do: @question

  @doc "Launches the prompt for `session`; returns `{session, received_path}`."
  def start(session) do
    socket = "fm-prompt-#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), socket)
    File.mkdir_p!(dir)
    executable = Path.join(dir, "prompt")

    File.write!(executable, """
    #!/bin/sh
    stty raw -echo
    draw() {
      clear
      printf 'Which database?\\r\\n\\r\\n%s 1. Postgres\\r\\n     Durable\\r\\n  2. SQLite\\r\\n%s 3. Type something.\\r\\n' "$1" "$2"
    }
    draw '❯' ' '
    printf ready > ready
    while :; do
      c=$(dd bs=1 count=1 2>/dev/null)
      printf '%s' "$c" >> received
      case "$c" in
        1|2) clear; printf 'answered\\r\\n' ;;
        3) draw ' ' '❯' ;;
      esac
    done
    """)

    File.chmod!(executable, 0o700)

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

    old = Application.get_env(:foreman, :planning_tmux_socket)
    Application.put_env(:foreman, :planning_tmux_socket, socket)

    on_exit(fn ->
      if old,
        do: Application.put_env(:foreman, :planning_tmux_socket, old),
        else: Application.delete_env(:foreman, :planning_tmux_socket)

      System.cmd("tmux", ["-L", socket, "kill-server"], stderr_to_stdout: true)
      File.rm_rf!(dir)
    end)

    session = session |> Ecto.Changeset.change(workdir: dir) |> Repo.update!()
    {:ok, window} = Foreman.SessionTmux.launch(session, "flow", executable: executable)
    session = session |> Ecto.Changeset.change(window: window) |> Repo.update!()
    true = eventually(fn -> File.exists?(Path.join(dir, "ready")) end)
    {session, Path.join(dir, "received")}
  end

  def received(path) do
    case File.read(path) do
      {:ok, bytes} -> bytes
      _ -> ""
    end
  end

  def eventually(fun, attempts \\ 100)
  def eventually(_, 0), do: false

  def eventually(fun, n) do
    if fun.() do
      true
    else
      receive do
      after
        20 -> eventually(fun, n - 1)
      end
    end
  end
end
