defmodule Foreman.FsmMachinesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Foreman.Stage
  alias Foreman.Epic

  test "stage happy path follows Decision 7 and suggests close only on entering merged" do
    steps = [
      {:dispatch, :dispatched, [record: :session, emit: :stage]},
      {:progress, :building, [append: :progress, emit: :stage]},
      {:report, :reported, [record: :report, emit: :stage]},
      {:review, :in_review, [emit: :stage]},
      {:commit, :committed, [record: :commit, emit: :stage]},
      {:cr_opened, :pr_open, [link: :cr, emit: :stage]},
      {:cr_merged, :merged, [record: :merge, emit: :stage, suggest: :close_bead]},
      {:progress, :merged, [append: :progress, emit: :stage]},
      {:bead_closed, :done, [emit: :stage]},
      {:bead_reopened, :queued, [emit: :stage]}
    ]

    Enum.reduce(steps, :queued, fn {event, next, effects}, state ->
      assert Stage.step(state, event, %{}) == {next, effects}
      next
    end)
  end

  test "stage guarded branches, review fallout and specific bead-close effects" do
    assert Stage.step(:building, {:dispatch, %{window: "new"}}, %{session_window: "old"}) ==
             {:dispatched, [record: :session, append: :redispatched, emit: :stage]}

    assert Stage.step(:building, {:dispatch, %{window: "same"}}, %{session_window: "same"}) ==
             {:error, {:invalid, :building, {:dispatch, %{window: "same"}}}}

    assert Stage.step(:pr_open, {:cr_closed, %{number: 1}}, %{open_crs: [1, 2]}) ==
             {:pr_open, [unlink: :cr, emit: :stage]}

    assert Stage.step(:pr_open, {:cr_closed, %{number: 1}}, %{open_crs: [1]}) ==
             {:committed, [unlink: :cr, emit: :stage]}

    assert Stage.step(:pr_open, :bead_closed, %{}) ==
             {:done, [flag: :closed_with_open_cr, emit: :stage]}

    assert Stage.step(:in_review, :request_changes, %{}) ==
             {:building, [append: :finding, emit: :stage]}

    assert Stage.step(:building, :abandon, %{}) == {:abandoned, [emit: :stage]}
    assert Stage.step(:abandoned, :revive, %{}) == {:queued, [emit: :stage]}
  end

  test "epic draft lifecycle requires the linked beads id" do
    assert Epic.step(:new_draft, :create, %{}) == {:idea, [record: :draft]}
    assert Epic.step(:idea, :start_spec, %{}) == {:speccing, []}

    assert Epic.step(:speccing, :approve_spec, %{}) ==
             {:spec_approved, [record: :spec_link, record: :design_link]}

    assert Epic.step(:spec_approved, :ticket, %{}) ==
             {:error, {:invalid, :spec_approved, :ticket}}

    assert Epic.step(:spec_approved, {:ticket, %{beads_epic_id: "bb-c2w"}}, %{}) ==
             {:ticketed, [link: :beads_epic]}

    assert Epic.step(:ticketed, :bead_epic_closed, %{}) == {:done, []}
    assert Epic.step(:done, :bead_epic_reopened, %{}) == {:ticketed, []}
    assert Epic.step(:idea, :abandon, %{}) == {:abandoned, []}
    assert Epic.step(:abandoned, :revive, %{}) == {:idea, []}
  end

  for machine <- [Stage, Epic] do
    property "#{inspect(machine)} random event sequences never raise or leave declared states" do
      machine = unquote(machine)

      check all(
              events <-
                list_of(tuple({member_of(machine.__fsm__(:events)), term()}), max_length: 100),
              data <- term()
            ) do
        Enum.reduce(events, machine.__fsm__(:initial), fn event, state ->
          case machine.step(state, event, data) do
            {:error, {:invalid, ^state, ^event}} ->
              state

            {next, effects} ->
              assert next in machine.__fsm__(:states)
              assert is_list(effects)
              next
          end
        end)
      end
    end

    property "#{inspect(machine)} observed events are never invalid from any state" do
      machine = unquote(machine)
      observed = for {event, :observed} <- machine.__fsm__(:sources), do: event

      check all(
              state <- member_of(machine.__fsm__(:states)),
              event <- member_of(observed),
              payload <- term(),
              data <- term()
            ) do
        result = machine.step(state, {event, payload}, data)
        refute match?({:error, _}, result)
        assert elem(result, 0) in machine.__fsm__(:states)
      end
    end
  end
end
