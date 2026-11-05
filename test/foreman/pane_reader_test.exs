defmodule Foreman.PaneReaderTest do
  @moduledoc "The pane reader machine (spec Decision 14; design pack State, Proposed: pane reader)."
  use ExUnit.Case, async: true
  alias Foreman.PaneReader, as: M

  @shown %{live: true, shown: true, visible: true}
  @hidden_tab %{live: true, shown: false, visible: true}
  @hidden_doc %{live: true, shown: true, visible: false}
  @gone %{live: false, shown: true, visible: true}
  @t0 ~U[2026-11-05 12:00:00Z]
  @fresh %{hash: nil, saved_hash: nil, saved_at: nil}

  defp at(seconds), do: DateTime.add(@t0, seconds)

  describe "off" do
    test "a page that shows a live pane's output starts polling with a capture now" do
      assert M.step(:off, {:view, @shown}, @fresh) == {:polling, [capture: :pane]}
    end

    test "a live pane whose output is not shown stays unread" do
      assert M.step(:off, {:view, @hidden_tab}, @fresh) == {:paused, []}
      assert M.step(:off, {:view, @hidden_doc}, @fresh) == {:paused, []}
    end

    test "a dead pane is never read" do
      assert M.step(:off, {:view, @gone}, @fresh) == {:off, []}
    end

    test "late timers and results are ignored" do
      for event <- [:tick, {:captured, %{hash: "a", at: @t0}}, :failed],
          do: assert(M.step(:off, event, @fresh) == {:off, []})
    end
  end

  describe "polling" do
    test "each tick captures" do
      assert M.step(:polling, :tick, @fresh) == {:polling, [capture: :pane]}
    end

    test "a changed capture pushes, saves the first time, and waits a tick" do
      assert M.step(:polling, {:captured, %{hash: "a", at: @t0}}, @fresh) ==
               {:polling, [push: :output, save: :capture, timer: :tick]}
    end

    test "a changed capture within 10 s of the last save pushes without saving" do
      data = %{hash: "a", saved_hash: "a", saved_at: @t0}

      assert M.step(:polling, {:captured, %{hash: "b", at: at(9)}}, data) ==
               {:polling, [push: :output, timer: :tick]}

      assert M.step(:polling, {:captured, %{hash: "b", at: at(10)}}, data) ==
               {:polling, [push: :output, save: :capture, timer: :tick]}
    end

    test "an unchanged capture pushes nothing" do
      data = %{hash: "a", saved_hash: "a", saved_at: @t0}

      assert M.step(:polling, {:captured, %{hash: "a", at: at(30)}}, data) ==
               {:polling, [timer: :tick]}
    end

    test "a failed capture is a tmux error and retries later" do
      assert M.step(:polling, :failed, @fresh) ==
               {:tmux_error, [cancel: :timer, push: :error, timer: :retry]}
    end

    test "a hidden tab or another tab pauses and stops the timer" do
      data = %{hash: "a", saved_hash: "a", saved_at: @t0}
      assert M.step(:polling, {:view, @hidden_doc}, data) == {:paused, [cancel: :timer]}
      assert M.step(:polling, {:view, @hidden_tab}, data) == {:paused, [cancel: :timer]}
    end

    test "pausing saves output that was shown but not saved yet" do
      data = %{hash: "b", saved_hash: "a", saved_at: @t0}

      assert M.step(:polling, {:view, @hidden_doc}, data) ==
               {:paused, [cancel: :timer, save: :capture]}
    end

    test "a pane that is gone turns the reader off" do
      data = %{hash: "a", saved_hash: "a", saved_at: @t0}
      assert M.step(:polling, {:view, @gone}, data) == {:off, [cancel: :timer]}

      assert M.step(:polling, {:view, @gone}, %{data | hash: "b"}) ==
               {:off, [cancel: :timer, save: :capture]}
    end

    test "closing the page turns the reader off and keeps unsaved output" do
      assert M.step(:polling, :closed, %{hash: "b", saved_hash: "a", saved_at: @t0}) ==
               {:off, [cancel: :timer, save: :capture]}

      assert M.step(:polling, :closed, %{hash: "a", saved_hash: "a", saved_at: @t0}) ==
               {:off, [cancel: :timer]}
    end

    test "a repeated view keeps polling without a second capture" do
      assert M.step(:polling, {:view, @shown}, @fresh) == {:polling, []}
    end

    test "Try again now is refused while tmux answers" do
      assert M.step(:polling, :retry, @fresh) == {:error, {:invalid, :polling, :retry}}
    end
  end

  describe "paused" do
    test "no ticks or results are read while hidden" do
      assert M.step(:paused, :tick, @fresh) == {:paused, []}
      assert M.step(:paused, {:captured, %{hash: "a", at: @t0}}, @fresh) == {:paused, []}
      assert M.step(:paused, :failed, @fresh) == {:paused, []}
    end

    test "the tab shown again polls with a capture now" do
      assert M.step(:paused, {:view, @shown}, @fresh) == {:polling, [capture: :pane]}
    end

    test "a pane that is gone turns the reader off" do
      assert M.step(:paused, {:view, @gone}, @fresh) == {:off, []}
      assert M.step(:paused, :closed, @fresh) == {:off, []}
    end
  end

  describe "tmux error" do
    test "retries on its timer" do
      assert M.step(:tmux_error, :tick, @fresh) == {:tmux_error, [capture: :pane]}
      assert M.step(:tmux_error, :failed, @fresh) == {:tmux_error, [timer: :retry]}
    end

    test "Try again now stops the retry timer and captures at once" do
      assert M.step(:tmux_error, :retry, @fresh) == {:retrying, [cancel: :timer, capture: :pane]}
    end

    test "Try again now that fails says so and waits for the next retry" do
      assert M.step(:retrying, :failed, @fresh) ==
               {:tmux_error, [push: :still_down, timer: :retry]}
    end

    test "Try again now that works polls again" do
      assert M.step(:retrying, {:captured, %{hash: "a", at: @t0}}, @fresh) ==
               {:polling, [push: :output, save: :capture, timer: :tick]}
    end

    test "while Try again now runs, a second press is refused and ticks are ignored" do
      assert M.step(:retrying, :retry, @fresh) == {:error, {:invalid, :retrying, :retry}}
      assert M.step(:retrying, :tick, @fresh) == {:retrying, []}
    end

    test "while Try again now runs, a hidden tab pauses and a gone pane turns it off" do
      assert M.step(:retrying, {:view, @hidden_doc}, @fresh) == {:paused, []}
      assert M.step(:retrying, {:view, @gone}, @fresh) == {:off, []}
      assert M.step(:retrying, :closed, @fresh) == {:off, []}
    end

    test "a capture that works again polls and pushes even an unchanged screen" do
      data = %{hash: "a", saved_hash: "a", saved_at: @t0}

      assert M.step(:tmux_error, {:captured, %{hash: "a", at: at(1)}}, data) ==
               {:polling, [cancel: :timer, push: :output, timer: :tick]}
    end

    test "a hidden tab pauses; a gone pane or a closed page turns it off" do
      assert M.step(:tmux_error, {:view, @hidden_doc}, @fresh) == {:paused, [cancel: :timer]}
      assert M.step(:tmux_error, {:view, @gone}, @fresh) == {:off, [cancel: :timer]}
      assert M.step(:tmux_error, :closed, @fresh) == {:off, [cancel: :timer]}
    end
  end
end
