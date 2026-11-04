defmodule Foreman.Answers.Notice do
  @moduledoc "Saved-answer feedback. Archive can be undone until its five-second notice expires."
  use Foreman.Fsm
  initial(:none)
  state(:none)
  state(:archived)
  state(:failed)
  event(:archive)
  event(:failed)
  event(:clear)
  transition(:archive, from: :any, to: :archived)
  transition(:failed, from: :any, to: :failed)
  transition(:clear, from: :any, to: :none)
end
