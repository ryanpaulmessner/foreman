defmodule Foreman.PreviewCheckMonitor do
  @moduledoc "Web-side reachability checks for review cards, including isolated web previews."
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, 15_000)
    Process.send_after(self(), :tick, interval)
    {:ok, interval}
  end

  @impl true
  def handle_info(:tick, interval) do
    try do
      Foreman.PreviewChecks.run()
    rescue
      error -> Logger.warning("preview checks skipped: " <> Exception.message(error))
    end

    Process.send_after(self(), :tick, interval)
    {:noreply, interval}
  end
end
