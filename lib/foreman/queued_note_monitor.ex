defmodule Foreman.QueuedNoteMonitor do
  @moduledoc """
  Worker-side timer for `Foreman.QueuedNotes.run/1`: every 3 s it types notes that wait
  for a busy coordinator once that coordinator's prompt is idle (fm-9mm.23).
  """
  use GenServer
  require Logger

  @interval 3_000

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
      Foreman.QueuedNotes.run(state.opts)
    rescue
      error -> Logger.warning("queued notes skipped: " <> Exception.message(error))
    end

    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end
end
