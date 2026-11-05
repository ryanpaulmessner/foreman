defmodule Foreman.SessionControlPanel do
  @moduledoc """
  The session page's control area (spec Decision 17), one per open page: `ready`, the
  in-page Stop confirm (`confirming`), and a control's result line (`result`).

  A result line stays until the next action or a later state change of the session
  (`changed`), or the next action that has no line of its own (`act`, Try again now when
  tmux answers again); the confirm closes on Keep it running (`keep`), on its own result,
  or when the session changes under it. Effects are data: `focus: :keep` puts the focus on
  Keep it running when the confirm opens; `show: :result` and `clear: :result` tell the
  page to show or drop the line.
  """
  use Foreman.Fsm, observed_never_invalid: true

  initial(:ready)
  state(:ready)
  state(:confirming)
  state(:result)

  event(:ask_stop)
  event(:keep)
  event(:done)
  event(:act)
  event(:changed, source: :observed)

  effects([:focus, :show, :clear])

  transition(:ask_stop,
    from: [:ready, :result],
    to: :confirming,
    do: [clear: :result, focus: :keep]
  )

  transition(:keep, from: :confirming, to: :ready)
  transition(:act, from: [:ready, :confirming, :result], to: :ready, do: [clear: :result])
  transition(:done, from: [:ready, :confirming, :result], to: :result, do: [show: :result])
  transition(:changed, from: [:confirming, :result], to: :ready, do: [clear: :result])

  invalid([:ask_stop, :keep], from: :any)
  ignore(:changed, from: :any)
end
