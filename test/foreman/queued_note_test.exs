defmodule Foreman.QueuedNoteTest do
  @moduledoc """
  The queued-note machine (fm-9mm.23): a note for a busy coordinator waits, is claimed
  only while its coordinator row is live, is typed at most once, and a stale attempt is
  never retried.
  """
  use ExUnit.Case, async: true
  alias Foreman.QueuedNote

  @now ~U[2026-11-06 12:00:00Z]
  defp tick(live, claimed_at \\ nil),
    do: {:tick, %{now: @now, coordinator_live: live, claimed_at: claimed_at}}

  test "a new note waits" do
    assert QueuedNote.__fsm__(:initial) == :queued
  end

  test "a check claims a waiting note while its coordinator is live, and saves the claim before typing" do
    assert QueuedNote.step(:queued, tick(true), %{}) == {:sending, [save: :claim, type: :note]}
  end

  test "a check leaves the note waiting while its coordinator has ended" do
    assert QueuedNote.step(:queued, tick(false), %{}) == {:queued, []}
  end

  test "typed text and Enter make the note sent" do
    assert QueuedNote.step(:sending, :typed, %{}) == {:sent, [save: :sent]}
  end

  test "a prompt that is not idle types nothing, so the note waits again" do
    assert QueuedNote.step(:sending, :not_idle, %{}) == {:queued, [save: :release]}
  end

  test "tmux failing after typing began fails the note, never retried" do
    assert QueuedNote.step(:sending, :typing_failed, %{}) == {:failed, [save: :failed]}
  end

  test "an attempt older than the limit (the board stopped mid-send) fails, never retried" do
    old = DateTime.add(@now, -QueuedNote.stale_after() - 1, :second)
    assert QueuedNote.step(:sending, tick(true, old), %{}) == {:failed, [save: :lost]}

    fresh = DateTime.add(@now, -1, :second)
    assert QueuedNote.step(:sending, tick(true, fresh), %{}) == {:sending, []}
  end

  test "you can stop a waiting note, not one being typed or done" do
    assert QueuedNote.step(:queued, :withdraw, %{}) == {:withdrawn, [save: :withdrawn]}

    for state <- [:sending, :sent, :failed, :withdrawn],
        do: assert({:error, _} = QueuedNote.step(state, :withdraw, %{}))
  end

  test "a done note ignores checks and refuses attempt results" do
    for state <- [:sent, :failed, :withdrawn] do
      assert QueuedNote.step(state, tick(true), %{}) == {state, []}

      for event <- [:typed, :not_idle, :typing_failed],
          do: assert({:error, _} = QueuedNote.step(state, event, %{}))
    end
  end

  test "attempt results are refused for a waiting note" do
    for event <- [:typed, :not_idle, :typing_failed],
        do: assert({:error, _} = QueuedNote.step(:queued, event, %{}))
  end

  test "load/1 reads a stored state and refuses an unknown one" do
    assert QueuedNote.load("sending") == :sending
    assert_raise ArgumentError, fn -> QueuedNote.load("lost") end
  end
end
