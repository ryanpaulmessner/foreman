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
