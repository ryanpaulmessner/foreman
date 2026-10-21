defmodule Foreman.TicketStatusMachineTest do
  use ExUnit.Case, async: true
  alias Foreman.TicketStatusMachine

  test "park reaches parked from every status" do
    for status <- TicketStatusMachine.__fsm__(:states) do
      assert {:parked, []} = TicketStatusMachine.step(status, :park, nil)
    end
  end

  test "reopen and start take a ticket out of parked" do
    assert {:open, []} = TicketStatusMachine.step(:parked, :reopen, nil)
    assert {:in_progress, []} = TicketStatusMachine.step(:parked, :start, nil)
  end
end
