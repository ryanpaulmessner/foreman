defmodule Foreman.RequestWait do
  @moduledoc "CLI polling lifecycle. Deadlines return the last authoritative snapshot."
  use Foreman.Fsm
  initial(:waiting)
  state(:waiting)
  state(:retrying)
  state(:finished)
  event(:response)
  event(:timeout)
  effects([:reply, :poll, :warn, :recover, :remember])
  guard(:resolved?)
  guard(:snapshot?)
  guard(:missing?)
  guard(:warning_due?)
  guard(:recovered_result?)
  guard(:recovered_snapshot?)

  transition(:response, from: :waiting, to: :finished, guard: :missing?, do: [reply: :result])
  transition(:response, from: :waiting, to: :finished, guard: :resolved?, do: [reply: :result])
  transition(:response, from: :waiting, to: :stay, guard: :snapshot?, do: [poll: :again])

  transition(:response,
    from: :waiting,
    to: :retrying,
    guard: :warning_due?,
    do: [remember: :outage, warn: :unavailable, remember: :warning, poll: :again]
  )

  transition(:response, from: :waiting, to: :retrying, do: [remember: :outage, poll: :again])

  transition(:response,
    from: :retrying,
    to: :finished,
    guard: :recovered_result?,
    do: [recover: :available, reply: :result]
  )

  transition(:response, from: :retrying, to: :finished, guard: :missing?, do: [reply: :result])
  transition(:response, from: :retrying, to: :finished, guard: :resolved?, do: [reply: :result])

  transition(:response,
    from: :retrying,
    to: :waiting,
    guard: :recovered_snapshot?,
    do: [recover: :available, poll: :again]
  )

  transition(:response, from: :retrying, to: :waiting, guard: :snapshot?, do: [poll: :again])

  transition(:response,
    from: :retrying,
    to: :stay,
    guard: :warning_due?,
    do: [warn: :unavailable, remember: :warning, poll: :again]
  )

  transition(:response, from: :retrying, to: :stay, do: [poll: :again])
  transition(:timeout, from: [:waiting, :retrying], to: :finished, do: [reply: :current])
  invalid([:response, :timeout], from: :any)

  def resolved?(_, body),
    do: body["state"] in ~w(answered declined wrong_question withdrawn superseded done failed)

  def missing?(_, body), do: body["error"] == "not_found" and is_list(body["ids"])

  def snapshot?(_, body), do: body["state"] in ~w(pending approved executing)

  def warning_due?(data, _body),
    do: is_nil(data[:last_warning_at]) or data.now - data.last_warning_at >= 60_000

  def recovered_result?(data, body),
    do: (resolved?(data, body) or missing?(data, body)) and long_outage?(data)

  def recovered_snapshot?(data, body), do: snapshot?(data, body) and long_outage?(data)

  defp long_outage?(data),
    do: is_integer(data[:outage_started_at]) and data.now - data.outage_started_at >= 10_000
end
