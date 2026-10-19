defmodule Foreman.WaitingCard do
  @moduledoc """
  A session-waiting card's notice after Open session or an inline answer. Each card
  owns an instance; a successful Open clears the notice.
  """
  use Foreman.Fsm
  initial(:ready)
  state(:ready)
  state(:unattached)
  state(:window_gone)
  state(:prompt_changed)
  state(:tmux_unavailable)
  event(:opened)
  event(:no_client)
  event(:window_gone)
  event(:prompt_changed)
  event(:tmux_unavailable)
  transition(:opened, from: :any, to: :ready)
  transition(:no_client, from: :any, to: :unattached)
  transition(:window_gone, from: :any, to: :window_gone)
  transition(:prompt_changed, from: :any, to: :prompt_changed)
  transition(:tmux_unavailable, from: :any, to: :tmux_unavailable)
end
