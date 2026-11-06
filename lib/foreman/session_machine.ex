defmodule Foreman.SessionMachine do
  @moduledoc "Planning session lifecycle. Parking alone closes an unattached window; relaunch preserves the conversation identity."
  use Foreman.Fsm, observed_never_invalid: true
  initial(:new)
  state(:new)
  state(:starting)
  state(:running)
  state(:waiting)
  state(:ended)
  state(:parked)
  event(:launch)
  event(:adopt)
  event(:coordinator_resume)
  event(:coordinator_fresh)
  event(:started, source: :observed)
  event(:waiting, source: :observed)
  event(:resumed, source: :observed)
  event(:exited, source: :observed)
  event(:window_gone, source: :observed)
  event(:idle_timeout, source: :observed)
  event(:activity, source: :observed)
  event(:relaunch)
  event(:resume_on_model)
  event(:model_resume_failed)
  effects([:open, :clear, :close, :identity])
  guard(:parkable?)
  guard(:coordinator?)

  transition(:adopt,
    from: [:new, :ended],
    to: :ended,
    guard: :coordinator?,
    do: [identity: :adopt]
  )

  transition(:coordinator_resume,
    from: :new,
    to: :starting,
    guard: :coordinator?,
    do: [identity: :new, open: :window]
  )

  transition(:coordinator_resume,
    from: :ended,
    to: :starting,
    guard: :coordinator?,
    do: [identity: :keep, open: :resume]
  )

  transition(:coordinator_fresh,
    from: [:new, :ended],
    to: :starting,
    guard: :coordinator?,
    do: [identity: :new, open: :window]
  )

  invalid([:adopt, :coordinator_resume, :coordinator_fresh], from: :any)

  transition(:window_gone,
    from: [:starting, :running, :waiting, :ended],
    to: :ended,
    guard: :coordinator?,
    do: [clear: :waiting]
  )

  transition(:idle_timeout,
    from: [:running, :waiting, :ended],
    to: :parked,
    guard: :parkable?,
    do: [close: :window, clear: :waiting]
  )

  transition(:resume_on_model, from: [:starting, :running, :waiting], to: :starting)
  transition(:model_resume_failed, from: [:starting, :running, :waiting], to: :ended)
  invalid([:resume_on_model, :model_resume_failed], from: :any)

  transition(:relaunch, from: [:parked, :ended], to: :starting, do: [open: :resume])
  guard(:resume_matches?)
  transition(:launch, from: :new, to: :starting, do: [open: :window])
  transition(:started, from: :starting, to: :running)
  transition(:waiting, from: [:starting, :running], to: :waiting)

  transition(:resumed,
    from: :waiting,
    to: :running,
    guard: :resume_matches?,
    do: [clear: :waiting]
  )

  transition(:exited, from: [:running, :waiting], to: :ended, do: [clear: :waiting])

  transition(:window_gone,
    from: [:starting, :running, :waiting, :ended],
    to: :parked,
    do: [clear: :waiting]
  )

  ignore([:started, :waiting, :resumed, :exited, :window_gone, :idle_timeout, :activity],
    from: :any
  )

  invalid(:launch, from: :any)
  invalid(:relaunch, from: :any)

  def coordinator?(context, _), do: Map.get(context, :coordinator, false)
  def parkable?(context, _), do: not Map.get(context, :coordinator, false)
  def resume_matches?(context, _), do: Map.get(context, :resume_matches, true)
end
