defmodule Foreman.PreviewCheckTest do
  use ExUnit.Case, async: true
  alias Foreman.PreviewCheck

  test "checks move between unchecked, up and down; leaving pending stops all checks" do
    assert {:up, []} = PreviewCheck.step(:unchecked, :check_ok, %{})
    assert {:down, []} = PreviewCheck.step(:unchecked, :check_failed, %{})
    assert {:down, []} = PreviewCheck.step(:up, :check_failed, %{})
    assert {:up, []} = PreviewCheck.step(:down, :check_ok, %{})

    for state <- [:unchecked, :up, :down] do
      assert {:stopped, []} = PreviewCheck.step(state, :card_left_pending, %{})
    end

    for event <- [:check_ok, :check_failed, :card_left_pending] do
      assert {:stopped, []} = PreviewCheck.step(:stopped, event, %{})
    end
  end
end
