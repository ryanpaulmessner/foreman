defmodule Foreman.Answers.Expansion do
  @moduledoc "URL-driven answer expansion."
  use Foreman.Fsm
  initial(:closed)
  state(:closed)
  state(:open)
  event(:expand)
  event(:collapse)
  transition(:expand, from: :any, to: :open)
  transition(:collapse, from: :any, to: :closed)
end
