defmodule Foreman.CloseOutNagMonitor do
  @moduledoc "Worker-side timer for `Foreman.CloseOutNags.run/1`, once a minute."
  use GenServer
  require Logger

  @interval 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @interval)
    Process.send_after(self(), :tick, interval)
    {:ok, %{interval: interval, opts: Keyword.delete(opts, :interval)}}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      Foreman.CloseOutNags.run(state.opts)
    rescue
      error -> Logger.warning("close-out notes skipped: " <> Exception.message(error))
    end

    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end
end
