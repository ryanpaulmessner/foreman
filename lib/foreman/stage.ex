defmodule Foreman.Stage do
  @moduledoc "Ticket process stages (spec Decision 7). Persistence effects are interpreted by the overlay."
  use Foreman.Fsm, observed_never_invalid: true

  initial(:queued)
  state(:queued)
  state(:dispatched)
  state(:building)
  state(:reported)
  state(:in_review)
  state(:committed)
  state(:pr_open)
  state(:merged, enter: [suggest: :close_bead])
  state(:done)
  state(:abandoned)

  group(:live, [
    :queued,
    :dispatched,
    :building,
    :reported,
    :in_review,
    :committed,
    :pr_open,
    :merged
  ])

  group(:pre_pr, [:queued, :dispatched, :building, :reported, :in_review, :committed])
  group(:working, [:dispatched, :building])
  group(:after_report, [:reported, :in_review, :committed, :pr_open, :merged])

  event(:dispatch, source: :claimed)
  event(:progress, source: :claimed)
  event(:report, source: :claimed)
  event(:review, source: :claimed)
  event(:request_changes, source: :claimed)
  event(:commit, source: :claimed)
  event(:abandon, source: :claimed)
  event(:revive, source: :claimed)
  event(:cr_opened, source: :observed)
  event(:cr_closed, source: :observed)
  event(:cr_merged, source: :observed)
  event(:bead_closed, source: :observed)
  event(:bead_reopened, source: :observed)
  event(:jump, source: :observed)

  effects([:record, :append, :link, :unlink, :flag, :suggest, :emit])
  guard(:new_session?)
  guard(:other_open_cr?)

  transition(:dispatch, from: :queued, to: :dispatched, do: [record: :session, emit: :stage])

  transition(:dispatch,
    from: :working,
    to: :dispatched,
    guard: :new_session?,
    do: [record: :session, append: :redispatched, emit: :stage]
  )

  transition(:progress, from: :working, to: :building, do: [append: :progress, emit: :stage])
  transition(:progress, from: :after_report, to: :stay, do: [append: :progress, emit: :stage])
  transition(:report, from: :working, to: :reported, do: [record: :report, emit: :stage])
  transition(:review, from: :reported, to: :in_review, do: [emit: :stage])

  transition(:request_changes,
    from: :in_review,
    to: :building,
    do: [append: :finding, emit: :stage]
  )

  transition(:commit, from: :in_review, to: :committed, do: [record: :commit, emit: :stage])
  transition(:commit, from: :committed, to: :stay, do: [record: :commit, emit: :stage])
  transition(:abandon, from: :live, to: :abandoned, do: [emit: :stage])
  transition(:revive, from: :abandoned, to: :queued, do: [emit: :stage])
  transition(:cr_opened, from: :pre_pr, to: :pr_open, do: [link: :cr, emit: :stage])
  transition(:cr_opened, from: [:pr_open, :merged], to: :stay, do: [link: :cr, emit: :stage])

  transition(:cr_closed,
    from: :pr_open,
    to: :stay,
    guard: :other_open_cr?,
    do: [unlink: :cr, emit: :stage]
  )

  transition(:cr_closed, from: :pr_open, to: :committed, do: [unlink: :cr, emit: :stage])
  transition(:cr_merged, from: :pr_open, to: :merged, do: [record: :merge, emit: :stage])

  transition(:bead_closed,
    from: :pr_open,
    to: :done,
    do: [flag: :closed_with_open_cr, emit: :stage]
  )

  transition(:bead_closed, from: :live, to: :done, do: [emit: :stage])
  # A ticket closed with its PR still open keeps the link (and its preview) until the PR ends.
  transition(:cr_merged, from: :done, to: :stay, do: [unlink: :cr, emit: :stage])
  transition(:cr_closed, from: :done, to: :stay, do: [unlink: :cr, emit: :stage])
  transition(:bead_reopened, from: :done, to: :queued, do: [emit: :stage])
  transition(:jump, from: :queued, to: :stay, do: [emit: :stage])

  ignore([:cr_opened, :cr_closed, :cr_merged, :bead_closed, :bead_reopened, :jump], from: :any)

  invalid([:dispatch, :progress, :report, :review, :request_changes, :commit, :abandon, :revive],
    from: :any
  )

  def new_session?(%{session_window: current}, %{window: window}), do: window != current
  def new_session?(_, _), do: false

  def other_open_cr?(%{open_crs: numbers}, %{number: number}) when is_list(numbers),
    do: Enum.any?(numbers, &(&1 != number))

  def other_open_cr?(_, _), do: false
end
