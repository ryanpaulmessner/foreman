defmodule Foreman.SessionPane do
  @moduledoc """
  The one tmux pane a session's live controls act on (spec Decisions 17-18, R11).

  `resolve/2` finds the row's own pane and checks that it still belongs to the row before
  anything is typed into it or closed: the stored `%N` pane on the row's server (a window
  build with no stored pane uses the only pane of the window named after it), the board's
  `@foreman-session` window tag for board rows, and the working directory when the row
  has one. A window target is never used, because the active pane of a coordinator's
  window can be one of its pane-mode builds.

  `close/2` closes only that pane, never its window, so builds in the same window keep
  running. `continue/2` types exactly `continue` and Enter into it. Every call uses `-N`,
  so no call starts a tmux server. Options: `:runner` (a `System.cmd/3` stand-in) and
  `:key_delay` (ms between the typed word and Enter).
  """
  alias Foreman.AgentSession

  @format Enum.join(
            [
              "\#{pane_id}",
              "\#{window_name}",
              "\#{pane_active}",
              "\#{window_panes}",
              "\#{@foreman-session}",
              "\#{pane_current_path}"
            ],
            "\t"
          )

  @doc """
  The row's pane: `{:ok, %{socket, pane, server, board}}`, `{:error, :window_gone}` (no
  such pane), `{:error, :pane_changed}` (the pane no longer runs this session) or
  `{:error, :tmux_unavailable}`.
  """
  def resolve(%AgentSession{} = row, opts \\ []) do
    socket = socket(row.tmux_server)

    with {:ok, output} <- run(socket, ["list-panes", "-a", "-F", @format], opts),
         {:ok, pane} <- find(parse(output), row),
         :ok <- owned(pane, row) do
      {:ok, %{socket: socket, pane: pane.pane, server: server(row), board: board?(row)}}
    end
  end

  defp parse(output) do
    for line <- String.split(output, "\n", trim: true),
        [pane, name, active, panes, tag, path] <- [String.split(line, "\t")],
        do: %{pane: pane, name: name, active: active == "1", panes: panes, tag: tag, path: path}
  end

  defp find(panes, %{pane_id: "%" <> _ = id}) do
    case Enum.find(panes, &(&1.pane == id)) do
      nil -> {:error, :window_gone}
      pane -> {:ok, pane}
    end
  end

  # A window build recorded without a pane: the only pane of the window with its name.
  defp find(panes, %{tmux_server: "default", name: name}) when is_binary(name) do
    case Enum.filter(panes, &(&1.name == name)) do
      [%{panes: "1"} = pane] -> {:ok, pane}
      _ -> {:error, :window_gone}
    end
  end

  defp find(_, _), do: {:error, :window_gone}

  defp owned(pane, row) do
    cond do
      board?(row) and pane.tag != row.id -> {:error, :pane_changed}
      not same_dir?(pane.path, row.workdir) -> {:error, :pane_changed}
      true -> :ok
    end
  end

  # tmux reports the real path; the row may hold a symlinked one (/tmp, /private/tmp).
  defp same_dir?(_, dir) when dir in [nil, ""], do: true
  defp same_dir?("", _), do: true

  defp same_dir?(path, dir) do
    Path.expand(path) == Path.expand(dir) or
      case {File.stat(path), File.stat(dir)} do
        {{:ok, a}, {:ok, b}} -> {a.inode, a.major_device} == {b.inode, b.major_device}
        _ -> false
      end
  end

  @doc """
  Closes only `pane`. A board row's window loses its `@foreman-session` tag first, so the
  board stops treating the window (and the builds left in it) as the coordinator.
  """
  def close(%{socket: socket, pane: pane} = target, opts \\ []) do
    untag =
      if target[:board],
        do: ["set-option", "-w", "-u", "-t", pane, "@foreman-session", ";"],
        else: []

    with {:ok, _} <- run(socket, untag ++ ["kill-pane", "-t", pane], opts), do: :ok
  end

  @doc "Types exactly `continue`, then Enter, into `pane` (fm-3c3.9)."
  def continue(%{socket: socket, pane: pane}, opts \\ []) do
    with {:ok, _} <- run(socket, ["send-keys", "-t", pane, "-l", "continue"], opts) do
      # Claude reads typed text and Enter on separate renders; never coalesce them.
      Process.sleep(Keyword.get(opts, :key_delay, 150))
      with {:ok, _} <- run(socket, ["send-keys", "-t", pane, "Enter"], opts), do: :ok
    end
  end

  @doc "The card source shape for `pane`: Focus and Send message reach this pane only."
  def source(%AgentSession{} = row, %{pane: pane, server: server}),
    do: %{
      name: row.name,
      harness: row.harness,
      target: pane,
      server: server,
      agent_session_id: row.id,
      kind: row.kind
    }

  defp board?(row), do: row.tmux_server == "board"
  defp server(row), do: if(board?(row), do: :board, else: :default)

  @doc "The tmux socket name of a row's stored server (`board` or `default`)."
  def socket("board"), do: Application.get_env(:foreman, :planning_tmux_socket, "foreman")
  def socket(_), do: Application.get_env(:foreman, :external_tmux_socket, "default")

  defp run(socket, args, opts) do
    runner = Keyword.get(opts, :runner, &System.cmd/3)

    case runner.("tmux", ["-N", "-L", socket | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      _ -> {:error, :tmux_unavailable}
    end
  rescue
    ErlangError -> {:error, :tmux_unavailable}
  end
end
