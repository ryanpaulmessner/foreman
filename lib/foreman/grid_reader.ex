defmodule Foreman.GridReader do
  @moduledoc "One grid reader per page. Visibility changes never start an extra check."
  use Foreman.Fsm, observed_never_invalid: true
  initial(:off)
  state(:off)
  state(:polling)
  state(:paused)
  state(:tmux_error)
  state(:capturing)
  event(:view, source: :observed)
  event(:tick, source: :observed)
  event(:captured, source: :observed)
  event(:failed, source: :observed)
  event(:retry)
  effects([:capture, :cancel, :timer, :retry])
  guard(:watching?)
  guard(:hidden?)
  guard(:due?)
  transition(:view, from: :capturing, to: :stay, guard: :watching?)

  transition(:view,
    from: :capturing,
    to: :paused,
    guard: :hidden?,
    do: [cancel: :capture, timer: :check]
  )

  transition(:view, from: :capturing, to: :off, do: [cancel: :capture, timer: :check])
  transition(:view, from: :tmux_error, to: :stay, guard: :watching?)
  transition(:view, from: :any, to: :polling, guard: :watching?)
  transition(:view, from: :any, to: :paused, guard: :hidden?)
  transition(:view, from: :any, to: :off)

  transition(:tick,
    from: [:polling, :tmux_error],
    to: :capturing,
    guard: :due?,
    do: [capture: :visible]
  )

  transition(:tick, from: [:polling, :tmux_error], to: :stay, do: [timer: :check])
  transition(:captured, from: :capturing, to: :polling, do: [timer: :check])
  transition(:failed, from: :capturing, to: :tmux_error, do: [timer: :check])
  transition(:retry, from: :tmux_error, to: :stay, do: [retry: :visible])
  ignore(:retry, from: [:off, :paused, :polling, :capturing])
  transition(:tick, from: [:off, :paused], to: :stay, do: [timer: :check])
  ignore(:tick, from: :capturing)
  ignore([:captured, :failed], from: [:off, :paused, :polling, :tmux_error])
  def due?(_, nil), do: true
  def due?(_, payload), do: Map.get(payload, :due, true)
  def watching?(_, view), do: view.shown and view.visible
  def hidden?(_, view), do: view.shown and not view.visible

  def due(rows, visible, read_at, now) do
    Enum.filter(rows, fn row ->
      live = is_nil(row.ended_at) and row.state not in ["ended", "parked"]
      interval = if row.state == "idle", do: 30_000, else: 3_000
      last = Map.get(read_at, row.id)
      live and MapSet.member?(visible, row.id) and (is_nil(last) or now - last >= interval)
    end)
  end
end
