defmodule Foreman.SessionsView do
  @moduledoc "The viewer's Tree/Grid choice, restored by the browser when storage works."
  use Foreman.Fsm, observed_never_invalid: true
  initial(:tree)
  state(:tree)
  state(:grid)
  event(:tree, source: :observed)
  event(:grid, source: :observed)
  transition(:tree, from: :any, to: :tree)
  transition(:grid, from: :any, to: :grid)
end
