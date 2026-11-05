defmodule Foreman.SessionLifecycle do
  @moduledoc """
  The lifecycle of every `agent_sessions` row (spec Decision 7), with `kind` as a guard.

  Live states: starting, working, idle and the three waiting reasons. Dead states: parked
  and ended. `none` is the row before a writer creates it. Claimed events outside the table
  are refused; observed events outside it are ignored. Effects are data: the caller runs
  them (`Foreman.SessionControls` runs focus, message, continue, park and stop; later
  tickets run resume, start fresh and relaunch build).

  Data for the guards: `kind` (`main_coordinator`, `epic_coordinator`, `build`),
  `harness` (`claude`, `pi`) and `resumable` (see `Foreman.AgentSessions.resumable?/1`).
  """
  use Foreman.Fsm, observed_never_invalid: true

  initial(:none)
  state(:none)
  state(:starting)
  state(:working)
  state(:idle)
  state(:waiting_question)
  state(:waiting_permission)
  state(:waiting_usage_limit)
  state(:parked)
  state(:ended)

  group(:active, [:starting, :working, :idle])

  group(:live, [
    :starting,
    :working,
    :idle,
    :waiting_question,
    :waiting_permission,
    :waiting_usage_limit
  ])

  group(:dead, [:parked, :ended])

  event(:launch)
  event(:register)
  event(:continue)
  event(:focus)
  event(:message)
  event(:resume_on_model)
  event(:park)
  event(:stop)
  event(:resume)
  event(:start_fresh)
  event(:relaunch_build)
  event(:output_changed, source: :observed)
  event(:quiet, source: :observed)
  event(:asked, source: :observed)
  event(:last_card_closed, source: :observed)
  event(:permission_prompt, source: :observed)
  event(:usage_limit, source: :observed)
  event(:prompt_cleared, source: :observed)
  event(:idle_timeout, source: :observed)
  event(:pane_gone, source: :observed)
  event(:exited, source: :observed)

  effects([
    :write,
    :open,
    :request,
    :clear,
    :send,
    :show,
    :save,
    :stop,
    :close,
    :resume,
    :create,
    :move,
    :note
  ])

  guard(:parkable?)
  guard(:pi_build?)
  guard(:resumable?)
  guard(:fresh?)
  guard(:relaunch?)

  transition(:launch, from: :none, to: :starting, do: [write: :row, open: :window])
  transition(:register, from: :none, to: :starting, do: [write: :row])

  transition(:output_changed, from: [:starting, :idle], to: :working)
  transition(:output_changed, from: :waiting_usage_limit, to: :working, do: [clear: :request])
  transition(:quiet, from: :working, to: :idle)

  transition(:asked, from: :active, to: :waiting_question)

  transition(:permission_prompt,
    from: :active,
    to: :waiting_permission,
    do: [request: :permission]
  )

  transition(:usage_limit, from: :active, to: :waiting_usage_limit, do: [request: :usage_limit])
  transition(:last_card_closed, from: :waiting_question, to: :idle)
  transition(:prompt_cleared, from: :waiting_permission, to: :working, do: [clear: :request])

  transition(:continue, from: :waiting_usage_limit, to: :stay, do: [send: :continue])
  # The page's live controls (Decision 17): Focus in every live state; Send message only
  # where typing does not interrupt the agent.
  transition(:focus, from: :live, to: :stay, do: [show: :pane])
  transition(:message, from: [:idle, :waiting_question], to: :stay, do: [send: :message])

  transition(:resume_on_model,
    from: :waiting_usage_limit,
    to: :starting,
    guard: :pi_build?,
    do: [save: :capture, stop: :process, resume: :model]
  )

  transition([:park, :idle_timeout],
    from: :live,
    to: :parked,
    guard: :parkable?,
    do: [save: :capture, close: :pane]
  )

  transition(:stop, from: :live, to: :ended, do: [save: :capture, close: :pane])
  transition([:pane_gone, :exited], from: :live, to: :ended, do: [save: :capture])

  transition(:resume, from: :dead, to: :starting, guard: :resumable?, do: [resume: :conversation])

  transition(:start_fresh,
    from: :dead,
    to: :stay,
    guard: :fresh?,
    do: [create: :row, move: :builds]
  )

  transition(:relaunch_build,
    from: :ended,
    to: :stay,
    guard: :relaunch?,
    do: [resume: :parent, note: :relaunch]
  )

  invalid(
    [
      :launch,
      :register,
      :continue,
      :focus,
      :message,
      :resume_on_model,
      :park,
      :stop,
      :resume,
      :start_fresh,
      :relaunch_build
    ],
    from: :any
  )

  ignore(
    [
      :output_changed,
      :quiet,
      :asked,
      :last_card_closed,
      :permission_prompt,
      :usage_limit,
      :prompt_cleared,
      :idle_timeout,
      :pane_gone,
      :exited
    ],
    from: :any
  )

  @doc "Only epic coordinators park; builds and the main coordinator never do (R6)."
  def parkable?(data, _), do: Map.get(data, :kind) == "epic_coordinator"
  def pi_build?(data, _), do: Map.get(data, :kind) == "build" and Map.get(data, :harness) == "pi"
  def resumable?(data, _), do: Map.get(data, :resumable) == true

  def fresh?(data, _),
    do:
      Map.get(data, :kind) in ~w(main_coordinator epic_coordinator) and not resumable?(data, nil)

  def relaunch?(data, _), do: Map.get(data, :kind) == "build" and not resumable?(data, nil)

  @stored %{
    starting: "starting",
    working: "working",
    idle: "idle",
    waiting_question: "waiting.question",
    waiting_permission: "waiting.permission",
    waiting_usage_limit: "waiting.usage_limit",
    parked: "parked",
    ended: "ended"
  }
  @loaded Map.new(@stored, fn {atom, text} -> {text, atom} end)

  @doc "The column value of a state (`waiting.question` for `:waiting_question`)."
  def dump(state), do: Map.fetch!(@stored, state)

  @doc "The state of a column value; a row not yet written is `:none`."
  def load(nil), do: :none
  def load(text) when is_binary(text), do: Map.fetch!(@loaded, text)

  def stored, do: Map.values(@stored)
  def live?(state), do: state in __fsm__(:groups).live
end
