defmodule Foreman.ExternalSession do
  @moduledoc "External session liveness; ended_at stores the terminal state."
  use Foreman.Fsm
  initial(:running)
  state(:running)
  state(:ended)
  event(:register, source: :claimed)
  event(:pane_gone, source: :observed)
  effects([:save])
  transition(:register, from: [:running, :ended], to: :running, do: [save: :registration])
  transition(:pane_gone, from: :running, to: :ended, do: [save: :ended_at])
  ignore(:pane_gone, from: :ended)
end
