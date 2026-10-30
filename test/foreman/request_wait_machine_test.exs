defmodule Foreman.RequestWaitMachineTest do
  use ExUnit.Case, async: true
  alias Foreman.RequestWait, as: WaitMachine

  test "waiting states poll, outcomes return, failure streaks warn once, timeout returns" do
    for state <- ~w(pending approved executing) do
      assert WaitMachine.step(:waiting, {:response, %{"state" => state}}, %{}) ==
               {:waiting, [poll: :again]}
    end

    for state <- ~w(answered declined withdrawn superseded done failed) do
      assert WaitMachine.step(:waiting, {:response, %{"state" => state}}, %{}) ==
               {:finished, [reply: :result]}
    end

    assert WaitMachine.step(:waiting, {:response, %{"warning" => "unavailable"}}, %{}) ==
             {:retrying, [warn: :unavailable, poll: :again]}

    assert WaitMachine.step(:retrying, {:response, %{}}, %{}) ==
             {:retrying, [poll: :again]}

    assert WaitMachine.step(:retrying, {:response, %{"state" => "pending"}}, %{}) ==
             {:waiting, [poll: :again]}

    assert WaitMachine.step(:retrying, :timeout, %{}) == {:finished, [reply: :current]}

    assert WaitMachine.step(:waiting, :timeout, %{}) == {:finished, [reply: :current]}

    for event <- [:response, :timeout] do
      assert {:error, _} = WaitMachine.step(:finished, event, %{})
    end
  end
end
