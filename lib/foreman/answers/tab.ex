defmodule Foreman.Answers.Tab do
  @moduledoc "URL-driven Answers tab. Unknown or missing tabs select saved answers."
  use Foreman.Fsm
  initial(:saved)
  state(:saved)
  state(:yours)
  state(:rules)
  event(:select)
  guard(:yours?)
  guard(:rules?)
  transition(:select, from: :any, to: :yours, guard: :yours?)
  transition(:select, from: :any, to: :rules, guard: :rules?)
  transition(:select, from: :any, to: :saved)

  def yours?(%{tab: tab}, _), do: tab in [:yours, "yours"]
  def rules?(%{tab: tab}, _), do: tab in [:rules, "rules"]
end
