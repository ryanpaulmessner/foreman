defmodule Foreman.GridReaderTest do
  use ExUnit.Case, async: true
  alias Foreman.GridReader

  test "only visible live panes are due, working and waiting at 3s, idle and review at 30s" do
    rows =
      for {id, state} <- [
            {"work", "working"},
            {"wait", "waiting.question"},
            {"idle", "idle"},
            {"dead", "ended"},
            {"offscreen", "working"}
          ],
          do: %{id: id, state: state, ended_at: nil}

    visible = MapSet.new(["work", "wait", "idle", "dead"])
    last = Map.new(rows, &{&1.id, 0})
    assert Enum.map(GridReader.due(rows, visible, last, 3000), & &1.id) == ["work", "wait"]

    assert Enum.map(GridReader.due(rows, visible, last, 30000), & &1.id) == [
             "work",
             "wait",
             "idle"
           ]

    assert GridReader.due(rows, visible, last, 2999) == []
  end

  test "an empty check does not clear a tmux error" do
    assert {:tmux_error, [timer: :check]} =
             GridReader.step(:tmux_error, {:tick, %{due: false}}, %{})

    assert {:tmux_error, [retry: :visible]} = GridReader.step(:tmux_error, :retry, %{})
  end

  test "one batch in flight and hiding cancels it" do
    assert {:capturing, [capture: :visible]} = GridReader.step(:polling, :tick, %{})
    assert {:capturing, []} = GridReader.step(:capturing, :tick, %{})

    assert {:paused, [cancel: :capture, timer: :check]} =
             GridReader.step(:capturing, {:view, %{shown: true, visible: false}}, %{})

    assert {:paused, []} = GridReader.step(:paused, :captured, %{})
  end

  test "hidden and tree stop reads; visibility never captures immediately" do
    assert {:polling, []} = GridReader.step(:off, {:view, %{shown: true, visible: true}}, %{})
    assert {:capturing, [capture: :visible]} = GridReader.step(:polling, :tick, %{})
    assert {:paused, []} = GridReader.step(:polling, {:view, %{shown: true, visible: false}}, %{})
    assert {:paused, [timer: :check]} = GridReader.step(:paused, :tick, %{})
    assert {:off, []} = GridReader.step(:paused, {:view, %{shown: false, visible: true}}, %{})
    assert {:off, [timer: :check]} = GridReader.step(:off, :tick, %{})
  end
end
