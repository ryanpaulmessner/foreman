defmodule Foreman.SessionProcess do
  @moduledoc "Records and rechecks process identities before signalling a usage-limited agent by PID."

  def record(row, pane, opts) do
    with {:ok, output} <-
           tmux(pane.socket, ["display-message", "-p", "-t", pane.pane, "\#{pane_pid}"], opts),
         {root, ""} when root > 1 <- Integer.parse(String.trim(output)),
         {listing, 0} <- run("ps", ["-axo", "pid=,ppid=,comm="], opts),
         processes = parse(listing),
         [agent] <-
           Enum.filter(
             processes,
             &(harness?(&1.command, row.harness) and descendant?(&1.pid, root, processes))
           ),
         {:ok, identity} <- identity(agent.pid, opts),
         {:ok, root_identity} <- identity(root, opts) do
      {:ok,
       %{pid: agent.pid, identity: identity, root: root, root_identity: root_identity, pane: pane}}
    else
      _ -> {:error, :process_unverified}
    end
  end

  def stop(record, opts) do
    with :ok <- Foreman.Preview.allow_external_write(), do: stop_recorded(record, opts)
  end

  defp stop_recorded(record, opts) do
    if record.root == record.pid do
      with :ok <- untag(record, opts), do: terminate(record.pid, record.identity, opts)
    else
      with :ok <- terminate(record.pid, record.identity, opts) do
        case identity(record.root, opts) do
          :gone ->
            :ok

          {:ok, expected} when expected == record.root_identity ->
            with :ok <- untag(record, opts),
                 do: terminate(record.root, record.root_identity, opts)

          _ ->
            {:error, :process_changed}
        end
      end
    end
  end

  defp untag(%{pane: %{board: true} = pane, root: root, root_identity: expected}, opts) do
    with {:ok, ^expected} <- identity(root, opts),
         {:ok, _} <-
           tmux(
             pane.socket,
             ["set-option", "-w", "-u", "-t", pane.pane, "@foreman-session"],
             opts
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :process_changed}
    end
  end

  defp untag(_, _), do: :ok

  defp terminate(pid, expected, opts) do
    with :ok <- signal(pid, expected, "-TERM", opts) do
      case gone(pid, expected, opts, 30) do
        {:error, :process_still_running} ->
          with :ok <- signal(pid, expected, "-KILL", opts), do: gone(pid, expected, opts, 30)

        result ->
          result
      end
    end
  end

  defp signal(pid, expected, signal, opts) do
    with {:ok, ^expected} <- identity(pid, opts),
         {_, 0} <- run("kill", [signal, Integer.to_string(pid)], opts) do
      :ok
    else
      _ -> {:error, :process_changed}
    end
  end

  defp gone(_, _, _, 0), do: {:error, :process_still_running}

  defp gone(pid, expected, opts, attempts) do
    case identity(pid, opts) do
      :gone ->
        :ok

      {:ok, ^expected} ->
        Process.sleep(Keyword.get(opts, :poll_delay, 100))
        gone(pid, expected, opts, attempts - 1)

      _ ->
        {:error, :process_changed}
    end
  end

  defp identity(pid, opts) do
    case run("ps", ["-p", Integer.to_string(pid), "-o", "lstart=,stat=,comm="], opts) do
      {"", 1} ->
        :gone

      {text, 0} ->
        case String.split(String.trim(text), ~r/\s+/, parts: 7) do
          [day, month, date, time, year, status, command] ->
            if String.starts_with?(status, "Z"),
              do: :gone,
              else: {:ok, {day, month, date, time, year, command}}

          _ ->
            {:error, :process_unverified}
        end

      _ ->
        {:error, :process_unverified}
    end
  end

  defp parse(text) do
    for line <- String.split(text, "\n", trim: true),
        [pid, parent, command] <- [String.split(String.trim(line), ~r/\s+/, parts: 3)],
        {pid, ""} <- [Integer.parse(pid)],
        {parent, ""} <- [Integer.parse(parent)],
        do: %{pid: pid, parent: parent, command: command}
  end

  defp descendant?(pid, root, _) when pid == root, do: true
  defp descendant?(pid, _, _) when pid <= 1, do: false

  defp descendant?(pid, root, processes) do
    case Enum.find(processes, &(&1.pid == pid)) do
      %{parent: parent} when parent != pid -> descendant?(parent, root, processes)
      _ -> false
    end
  end

  defp harness?(command, harness), do: Path.basename(command) == harness

  defp tmux(socket, args, opts) do
    case run("tmux", ["-N", "-L", socket | args], opts) do
      {text, 0} -> {:ok, text}
      _ -> {:error, :tmux_unavailable}
    end
  end

  defp run(exe, args, opts) do
    Keyword.get(opts, :runner, &System.cmd/3).(exe, args, stderr_to_stdout: true)
  rescue
    ErlangError -> {"", 1}
  end
end
