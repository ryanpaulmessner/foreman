defmodule Foreman.AnswersUiMachinesTest do
  use ExUnit.Case, async: true
  alias Foreman.Answers.{Tab, Load, Notice}

  test "each URL choice selects its tab from every tab; absent and invalid choices select saved" do
    assert Tab.__fsm__(:initial) == :saved

    for from <- [:saved, :yours, :rules],
        {param, expected} <- [
          {"saved", :saved},
          {"yours", :yours},
          {"rules", :rules},
          {nil, :saved},
          {"unknown", :saved}
        ] do
      assert Tab.step(from, :select, %{tab: param}) == {expected, []}
    end
  end

  test "load failure can be retried from every load state" do
    assert Load.__fsm__(:initial) == :loading

    for from <- [:loading, :ready, :failed] do
      assert Load.step(from, :failed, %{}) == {:failed, []}
      assert Load.step(from, :loaded, %{}) == {:ready, []}
    end
  end

  test "archive, error and dismissal replace the previous notice" do
    assert Notice.__fsm__(:initial) == :none

    for from <- [:none, :archived, :failed] do
      assert Notice.step(from, :archive, %{}) == {:archived, []}
      assert Notice.step(from, :failed, %{}) == {:failed, []}
      assert Notice.step(from, :clear, %{}) == {:none, []}
    end
  end
end
