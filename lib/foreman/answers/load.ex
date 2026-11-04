defmodule Foreman.Answers.Load do
  @moduledoc "Answers list loading and retry; filters and the last rows survive a failed read."
  use Foreman.Fsm
  initial(:loading)
  state(:loading)
  state(:ready)
  state(:failed)
  event(:loaded)
  event(:failed)
  transition(:loaded, from: :any, to: :ready)
  transition(:failed, from: :any, to: :failed)
end
