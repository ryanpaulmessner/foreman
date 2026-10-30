defmodule Foreman.ScratchPrompt do
  @moduledoc """
  Stand-ins for Claude's prompts in a board-launched window on a scratch tmux
  server. Every keystroke byte is appended to `received`.

  - `start/1`: AskUserQuestion. The digits 1 and 2 answer (the screen then shows
    only "answered"), 3 moves the pointer to the free-text row.
  - `start_chat/2`: the chat input after a turn that ended on a question, either
    `:idle` (empty box) or `:busy` (a running turn). Enter starts a turn.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]
  alias Foreman.Repo

  @question %{
    "question" => "Which database?",
    "options" => ["Postgres", "SQLite"],
    "multi" => false
  }

  def question, do: @question

  @doc "Launches the question prompt for `session`; returns `{session, received_path}`."
  def start(session), do: launch(session, question_script())

  @doc "Launches the idle or busy chat input for `session`."
  def start_chat(session, mode) when mode in [:idle, :busy],
    do: launch(session, chat_script(mode))

  @doc "The chat stand-in as a shell script, for external windows."
  def chat_script(mode) do
    rule = String.duplicate("─", 40)

    idle =
      "printf '⏺ Shall I commit it?\\r\\n\\r\\n✻ Worked for 2s\\r\\n#{rule}\\r\\n❯ \\r\\n#{rule}\\r\\n  ? for shortcuts\\r\\n'"

    busy =
      "printf '✳ Concocting… (2s)\\r\\n#{rule}\\r\\n❯ \\r\\n#{rule}\\r\\n  esc to interrupt\\r\\n'"

    """
    #!/bin/sh
    stty raw -echo
    idle() { clear; #{idle}; }
    busy() { clear; #{busy}; }
    #{mode}
    printf ready > ready
    while :; do
      c=$(dd bs=1 count=1 2>/dev/null)
      printf '%s' "$c" >> received
      case "$c" in
        "$(printf '\\r')") busy ;;
      esac
    done
    """
  end

  defp launch(session, script) do
    socket = Foreman.TestTmux.socket("fm-prompt")
    dir = Path.join(System.tmp_dir!(), socket)
    File.mkdir_p!(dir)
    executable = Path.join(dir, "prompt")
    File.write!(executable, script)
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

  defp question_script do
    """
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
    """
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
