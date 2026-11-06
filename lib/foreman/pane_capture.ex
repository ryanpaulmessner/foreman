defmodule Foreman.PaneCapture do
  @moduledoc """
  One read-only `tmux capture-pane -p -e -J -S -200` of a session's pane (spec Decision 14).

  The tmux server comes from the row's stored server: `board` rows use the planning socket
  and `default` rows the external socket; when both name one tmux server
  (`Foreman.AgentSessions.same_servers/1`) either label reaches it. `-N` never starts a
  server. The capture never changes the pane, never attaches a client and never needs
  the preview's external-write permission.
  """
  alias Foreman.{AgentSession, AgentSessions}

  @lines 200
  @timeout 5_000

  @doc "Where to read `row`: `%{socket: name, target: pane or window}`."
  def target(%AgentSession{} = row) do
    %{server: server, target: target} = AgentSessions.target(row)
    %{socket: socket(server), target: target}
  end

  @doc """
  Captures the target's last #{@lines} lines with colour codes. Returns `{:ok, text}` or
  `{:error, :tmux_unavailable}` (no server, no such pane, or no answer in #{div(@timeout, 1000)} s).
  Options: `:runner` (a `System.cmd/3` stand-in; defaults to the `:pane_capture_runner`
  application setting, else `System.cmd/3`).
  """
  def read(%{socket: socket, target: target}, opts \\ []) when is_binary(target) do
    runner =
      Keyword.get_lazy(opts, :runner, fn ->
        Application.get_env(:foreman, :pane_capture_runner, &System.cmd/3)
      end)

    task = Task.async(fn -> run(runner, ["-N", "-L", socket | args(target)]) end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :tmux_unavailable}
    end
  end

  @doc "Read visible targets in one client per distinct socket (decision 54d0a459)."
  def read_batch(targets, opts \\ []) do
    runner =
      Keyword.get(
        opts,
        :runner,
        Application.get_env(:foreman, :pane_capture_runner, &System.cmd/3)
      )

    targets
    |> Enum.group_by(& &1.socket)
    |> Enum.reduce(%{}, fn {socket, panes}, acc ->
      marker = "foreman-" <> Base.encode16(:crypto.strong_rand_bytes(16))

      commands =
        Enum.with_index(panes)
        |> Enum.flat_map(fn {pane, index} ->
          target = "'" <> String.replace(pane.target, "'", "'\\''") <> "'"

          [
            "display-message",
            "-p",
            "#{marker}:#{index}:start",
            ";",
            "if-shell",
            "-F",
            "1",
            "capture-pane -p -e -J -S -200 -t #{target} ; display-message -p '#{marker}:#{index}:ok'",
            ";",
            "display-message",
            "-p",
            "#{marker}:#{index}:end",
            ";"
          ]
        end)
        |> Enum.drop(-1)

      task =
        Task.async(fn ->
          try do
            runner.("tmux", ["-N", "-L", socket | commands], stderr_to_stdout: true)
          rescue
            ErlangError -> {"", 1}
          end
        end)

      output =
        case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, {text, _}} -> String.replace_invalid(text)
          _ -> ""
        end

      Enum.with_index(panes)
      |> Enum.reduce(acc, fn {pane, index}, result ->
        start = "#{marker}:#{index}:start\n"
        finish = "#{marker}:#{index}:ok\n"

        value =
          case String.split(output, start, parts: 2) do
            [_, rest] ->
              case String.split(rest, "#{marker}:#{index}:end", parts: 2)
                   |> hd()
                   |> String.split(finish, parts: 2) do
                [text, _] -> {:ok, text}
                _ -> {:error, :tmux_unavailable}
              end

            _ ->
              {:error, :tmux_unavailable}
          end

        Map.put(result, pane.id, value)
      end)
    end)
  end

  defp run(runner, args) do
    case runner.("tmux", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.replace_invalid(out)}
      _ -> {:error, :tmux_unavailable}
    end
  rescue
    ErlangError -> {:error, :tmux_unavailable}
  end

  @doc "The `capture-pane` arguments for `target`, without a server."
  def args(target), do: ["capture-pane", "-p", "-e", "-J", "-S", "-#{@lines}", "-t", target]

  @doc "The capture's fingerprint; the page gets new output only when it changes."
  def hash(text), do: :crypto.hash(:sha256, text)

  defp socket(:board), do: Application.get_env(:foreman, :planning_tmux_socket, "foreman")
  defp socket(_), do: Application.get_env(:foreman, :external_tmux_socket, "default")
end
