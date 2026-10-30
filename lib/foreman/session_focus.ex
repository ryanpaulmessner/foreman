defmodule Foreman.SessionFocus do
  @moduledoc "One focus boundary: switch the latest tmux client, then raise the terminal."

  def show(target, run, opts \\ []) do
    with {:ok, output} <- run.(["list-clients", "-F", "\#{client_activity}\t\#{client_name}"]),
         {:ok, client} <- latest(output),
         {:ok, _} <- run.(["switch-client", "-c", client, "-t", target]) do
      Foreman.Terminal.activate(opts)
    else
      {:error, :no_client} = error -> error
      _ -> {:error, :tmux_unavailable}
    end
  end

  defp latest(output) do
    clients =
      for line <- String.split(output, "\n", trim: true),
          [activity, name] <- [String.split(line, "\t", parts: 2)],
          {time, ""} <- [Integer.parse(activity)],
          do: {time, name}

    case Enum.sort(clients, :desc) do
      [{_, client} | _] -> {:ok, client}
      [] -> {:error, :no_client}
    end
  end
end
