defmodule Foreman.SessionsConnection do
  @moduledoc "Read health for the Sessions outline; the browser owns transport disconnection."
  use Foreman.Fsm
  initial(:connecting)
  state(:connecting)
  state(:live)
  state(:tmux_error)
  event(:read_ok, source: :observed)
  event(:read_failed, source: :observed)
  transition(:read_ok, from: [:connecting, :live, :tmux_error], to: :live)
  transition(:read_failed, from: [:connecting, :live, :tmux_error], to: :tmux_error)
end
