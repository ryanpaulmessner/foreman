defmodule Foreman.CloseOutNag do
  @moduledoc """
  Note schedule for one item of stuck agent close-out work (see
  `Foreman.WaitingWithoutCard.stuck/0`).

  A `tick` asks for a note when one is due: `first_after/0` after the item got stuck,
  `repeat_every/0` after a note was delivered or failed, `busy_retry/0` after the owner's
  pane was busy. The attempt's result is the next event. An item with no owner waits for
  a change. A change to the item's stage or cards starts a new schedule; an item that is
  no longer stuck is cleared.

  Data: `%{stuck_since, last_noted_at}`; tick payload: `%{now: DateTime}`.
  """
  use Foreman.Fsm

  @first_after 30 * 60
  @repeat_every 3 * 60 * 60
  @busy_retry 10 * 60

  def first_after, do: @first_after
  def repeat_every, do: @repeat_every
  def busy_retry, do: @busy_retry

  initial(:waiting)
  state(:waiting)
  state(:noted)
  state(:busy)
  state(:ownerless)
  state(:cleared)
  group(:open, [:waiting, :noted, :busy, :ownerless])
  event(:tick, source: :observed)
  event(:delivered, source: :observed)
  event(:skipped, source: :observed)
  event(:pane_busy, source: :observed)
  event(:no_owner, source: :observed)
  event(:changed, source: :observed)
  event(:resolved, source: :observed)
  effects([:note, :save])
  guard(:first_due?)
  guard(:repeat_due?)
  guard(:retry_due?)

  transition(:tick, from: :waiting, to: :stay, guard: :first_due?, do: [note: :owner])
  transition(:tick, from: :noted, to: :stay, guard: :repeat_due?, do: [note: :owner])
  transition(:tick, from: :busy, to: :stay, guard: :retry_due?, do: [note: :owner])
  ignore(:tick, from: :any)
  transition(:delivered, from: [:waiting, :noted, :busy], to: :noted, do: [save: :attempt])
  transition(:skipped, from: [:waiting, :noted, :busy], to: :noted, do: [save: :attempt])
  transition(:pane_busy, from: [:waiting, :noted, :busy], to: :busy, do: [save: :attempt])
  transition(:no_owner, from: [:waiting, :noted, :busy], to: :ownerless, do: [save: :attempt])
  invalid([:delivered, :skipped, :pane_busy, :no_owner], from: [:ownerless, :cleared])
  transition(:changed, from: :any, to: :waiting, do: [save: :restart])
  transition(:resolved, from: :open, to: :cleared, do: [save: :cleared])
  ignore(:resolved, from: :cleared)

  def first_due?(%{stuck_since: since}, %{now: now}), do: elapsed(since, now) >= @first_after
  def first_due?(_, _), do: false

  def repeat_due?(%{last_noted_at: last}, %{now: now}), do: elapsed(last, now) >= @repeat_every
  def repeat_due?(_, _), do: false

  def retry_due?(%{last_noted_at: last}, %{now: now}), do: elapsed(last, now) >= @busy_retry
  def retry_due?(_, _), do: false

  defp elapsed(%DateTime{} = from, %DateTime{} = now), do: DateTime.diff(now, from, :second)
  defp elapsed(_, _), do: -1
end
