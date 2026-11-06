defmodule Foreman.QueuedNote do
  @moduledoc """
  One note the board types into a coordinator's pane when the coordinator was busy:
  the R9 answer to an ended build's card or a Relaunch build note (fm-9mm.23). The note
  is bound to one coordinator row and is typed at most once.

  - `queued`: the note waits. A `tick` (the note monitor's check) claims it only while
    its coordinator row is live; an ended coordinator leaves it waiting, and it is never
    sent to another session.
  - `sending`: the claim is saved before any key is typed, so a crash cannot type the
    note twice. The attempt's result is the next event: `typed` (text and Enter went in),
    `not_idle` (the prompt was busy or held unsent text; nothing was typed) or
    `typing_failed` (tmux failed after typing began: the text may be in the pane).
    A `tick` that finds an attempt older than `stale_after/0` seconds (the board stopped
    mid-attempt) fails it.
  - `sent`, `failed`, `withdrawn` (you stopped a waiting note) are final.

  Tick payload: `%{now, coordinator_live, claimed_at}`.
  """
  use Foreman.Fsm

  @stale_after 60

  @doc "Seconds after which an unfinished attempt counts as lost."
  def stale_after, do: @stale_after

  initial(:queued)
  state(:queued)
  state(:sending)
  state(:sent)
  state(:failed)
  state(:withdrawn)
  group(:done, [:sent, :failed, :withdrawn])
  event(:tick, source: :observed)
  event(:typed, source: :observed)
  event(:not_idle, source: :observed)
  event(:typing_failed, source: :observed)
  event(:withdraw)
  effects([:save, :type])
  guard(:coordinator_live?)
  guard(:stale?)

  transition(:tick,
    from: :queued,
    to: :sending,
    guard: :coordinator_live?,
    do: [save: :claim, type: :note]
  )

  transition(:tick, from: :sending, to: :failed, guard: :stale?, do: [save: :lost])
  ignore(:tick, from: :any)
  transition(:typed, from: :sending, to: :sent, do: [save: :sent])
  transition(:not_idle, from: :sending, to: :queued, do: [save: :release])
  transition(:typing_failed, from: :sending, to: :failed, do: [save: :failed])
  invalid([:typed, :not_idle, :typing_failed], from: [:queued, :sent, :failed, :withdrawn])
  transition(:withdraw, from: :queued, to: :withdrawn, do: [save: :withdrawn])
  invalid(:withdraw, from: [:sending, :sent, :failed, :withdrawn])

  def coordinator_live?(_, %{coordinator_live: live}), do: live == true
  def coordinator_live?(_, _), do: false

  def stale?(_, %{now: %DateTime{} = now, claimed_at: %DateTime{} = at}),
    do: DateTime.diff(now, at, :second) > @stale_after

  def stale?(_, _), do: false

  @doc "The machine state stored as `text`."
  def load(text) do
    case Enum.find(__fsm__(:states), &(to_string(&1) == text)) do
      nil -> raise ArgumentError, "unknown queued note state #{inspect(text)}"
      state -> state
    end
  end
end
