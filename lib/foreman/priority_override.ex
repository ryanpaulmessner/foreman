defmodule Foreman.PriorityOverride do
  @moduledoc """
  Who owns a ticket's priority: the ticket file, or a board override that wins
  until a file sync carries the same value. Payloads are `%{priority, file}`:
  the board's value and the file's value.
  """
  use Foreman.Fsm
  initial(:file)
  state(:file)
  state(:board)
  event(:set)
  event(:synced)
  effects([:store, :clear])
  guard(:matches_file?)

  transition(:set, from: :file, to: :stay, guard: :matches_file?)
  transition(:set, from: :file, to: :board, do: [store: :override])
  transition(:set, from: :board, to: :file, guard: :matches_file?, do: [clear: :override])
  transition(:set, from: :board, to: :stay, do: [store: :override])
  transition(:synced, from: :board, to: :file, guard: :matches_file?, do: [clear: :override])
  transition(:synced, from: :board, to: :stay)
  ignore(:synced, from: :file)

  def matches_file?(_, %{priority: priority, file: file}), do: priority == file
  def matches_file?(_, _), do: false
end
