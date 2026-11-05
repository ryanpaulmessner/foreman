defmodule Foreman.PaneReader do
  @moduledoc """
  Reads one live pane for a page that shows it (spec Decision 14; design pack State,
  "Proposed: pane reader"). One instance per open page; the page runs the effects.

  `view` carries what the page shows: `live` (the pane exists), `shown` (the output tab
  is open) and `visible` (the browser tab is visible). Only a live, shown and visible pane
  is read, so no `capture-pane` runs for a pane that no page shows. `captured` carries the
  capture's `hash` and time `at`; it is pushed only when the hash changes. The latest
  output is saved as the poll fallback at most every 10 s, and once more when reading
  stops with output that was shown but not saved.

  Data: `hash` (last pushed), `saved_hash` and `saved_at` (last saved).

  `retry` is Try again now: `retrying` is a tmux error with that capture running.

  Effects: `capture: :pane` (run one capture now), `timer: :tick | :retry` (next capture
  in 1 s, or 5 s after a tmux error), `cancel: :timer`, `push: :output | :error |
  :still_down` (`still_down`: Try again now failed too), `save: :capture`.
  """
  use Foreman.Fsm, observed_never_invalid: true

  @save_every 10

  initial(:off)
  state(:off)
  state(:polling, exit: [cancel: :timer])
  state(:paused)
  state(:tmux_error, exit: [cancel: :timer])
  state(:retrying)
  group(:down, [:tmux_error, :retrying])
  group(:reading, [:polling, :tmux_error, :retrying])
  group(:idle, [:off, :paused])

  event(:view, source: :observed)
  event(:tick, source: :observed)
  event(:captured, source: :observed)
  event(:failed, source: :observed)
  event(:closed, source: :observed)
  event(:retry)

  effects([:capture, :timer, :cancel, :push, :save])

  guard(:watching?)
  guard(:hidden?)
  guard(:gone?)
  guard(:unsaved?)
  guard(:hidden_unsaved?)
  guard(:gone_unsaved?)
  guard(:changed?)
  guard(:save_due?)

  transition(:view, from: :idle, to: :polling, guard: :watching?, do: [capture: :pane])
  transition(:view, from: :off, to: :paused, guard: :hidden?)
  transition(:view, from: :paused, to: :off, guard: :gone?)
  ignore(:view, from: :idle)

  transition(:view, from: :reading, to: :off, guard: :gone_unsaved?, do: [save: :capture])
  transition(:view, from: :reading, to: :off, guard: :gone?)
  transition(:view, from: :reading, to: :paused, guard: :hidden_unsaved?, do: [save: :capture])
  transition(:view, from: :reading, to: :paused, guard: :hidden?)
  ignore(:view, from: :reading)

  transition(:tick, from: [:polling, :tmux_error], to: :stay, do: [capture: :pane])
  ignore(:tick, from: :retrying)

  transition(:captured,
    from: :polling,
    to: :stay,
    guard: :save_due?,
    do: [push: :output, save: :capture, timer: :tick]
  )

  transition(:captured,
    from: :polling,
    to: :stay,
    guard: :changed?,
    do: [push: :output, timer: :tick]
  )

  transition(:captured, from: :polling, to: :stay, do: [timer: :tick])

  transition(:captured,
    from: :down,
    to: :polling,
    guard: :save_due?,
    do: [push: :output, save: :capture, timer: :tick]
  )

  transition(:captured, from: :down, to: :polling, do: [push: :output, timer: :tick])

  transition(:failed, from: :polling, to: :tmux_error, do: [push: :error, timer: :retry])
  transition(:failed, from: :tmux_error, to: :stay, do: [timer: :retry])

  transition(:failed,
    from: :retrying,
    to: :tmux_error,
    do: [push: :still_down, timer: :retry]
  )

  transition(:retry, from: :tmux_error, to: :retrying, do: [capture: :pane])
  invalid(:retry, from: [:off, :polling, :paused, :retrying])

  transition(:closed, from: :reading, to: :off, guard: :unsaved?, do: [save: :capture])
  transition(:closed, from: :any, to: :off)

  ignore([:tick, :captured, :failed], from: :idle)

  def watching?(_, view), do: live?(view) and shown?(view)
  def hidden?(_, view), do: live?(view) and not shown?(view)
  def gone?(_, view), do: not live?(view)
  def unsaved?(data, _), do: not is_nil(data.hash) and data.hash != data.saved_hash
  def hidden_unsaved?(data, view), do: hidden?(data, view) and unsaved?(data, view)
  def gone_unsaved?(data, view), do: gone?(data, view) and unsaved?(data, view)
  def changed?(data, %{hash: hash}), do: hash != data.hash

  def save_due?(data, %{at: at} = capture) do
    changed?(data, capture) and
      (is_nil(data.saved_at) or DateTime.diff(at, data.saved_at) >= @save_every)
  end

  defp live?(view), do: Map.get(view, :live) == true
  defp shown?(view), do: Map.get(view, :shown) == true and Map.get(view, :visible) == true

  @doc "The data for a new reader."
  def data, do: %{hash: nil, saved_hash: nil, saved_at: nil}
end
