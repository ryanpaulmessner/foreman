defmodule Foreman.SessionControlPanelTest do
  use ExUnit.Case, async: true
  alias Foreman.SessionControlPanel, as: M

  test "Stop opens the confirm with the focus on Keep it running; Keep it running closes it" do
    assert M.step(:ready, :ask_stop, %{}) == {:confirming, [clear: :result, focus: :keep]}
    assert M.step(:confirming, :keep, %{}) == {:ready, []}
  end

  test "a result replaces the confirm or an older result" do
    for state <- [:ready, :confirming, :result],
        do: assert(M.step(state, :done, %{}) == {:result, [show: :result]})
  end

  test "the next action or a state change of the session drops the result line" do
    assert M.step(:result, :ask_stop, %{}) == {:confirming, [clear: :result, focus: :keep]}
    assert M.step(:result, :changed, %{}) == {:ready, [clear: :result]}
    assert M.step(:confirming, :changed, %{}) == {:ready, [clear: :result]}
    assert M.step(:ready, :changed, %{}) == {:ready, []}

    for state <- [:ready, :confirming, :result],
        do: assert(M.step(state, :act, %{}) == {:ready, [clear: :result]})
  end

  test "Keep it running and a second Stop outside their states are refused" do
    assert M.step(:ready, :keep, %{}) == {:error, {:invalid, :ready, :keep}}
    assert M.step(:confirming, :ask_stop, %{}) == {:error, {:invalid, :confirming, :ask_stop}}
  end
end
