defmodule Foreman.RequestWait do
  @moduledoc "CLI polling lifecycle. Deadlines return the last authoritative snapshot."
  use Foreman.Fsm
  initial(:waiting)
  state(:waiting)
  state(:retrying)
  state(:finished)
  event(:response)
  event(:timeout)
  effects([:reply, :poll, :warn])
  guard(:resolved?)
  guard(:snapshot?)
  transition(:response, from: :waiting, to: :finished, guard: :resolved?, do: [reply: :result])
  transition(:response, from: :waiting, to: :stay, guard: :snapshot?, do: [poll: :again])
  transition(:response, from: :waiting, to: :retrying, do: [warn: :unavailable, poll: :again])
  transition(:response, from: :retrying, to: :finished, guard: :resolved?, do: [reply: :result])
  transition(:response, from: :retrying, to: :waiting, guard: :snapshot?, do: [poll: :again])
  transition(:response, from: :retrying, to: :stay, do: [poll: :again])
  transition(:timeout, from: [:waiting, :retrying], to: :finished, do: [reply: :current])
  invalid([:response, :timeout], from: :any)

  def resolved?(_, body),
    do: body["state"] in ~w(answered declined withdrawn superseded done failed)

  def snapshot?(_, body), do: body["state"] in ~w(pending approved executing)
end
