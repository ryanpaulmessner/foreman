defmodule ForemanWeb.TicketAgeTest do
  use ExUnit.Case, async: true
  alias ForemanWeb.TicketAge

  test "compact ages use UTC calendar days, weeks and months" do
    today = ~D[2026-10-20]

    for {days, label} <- [
          {0, "today"},
          {1, "1d"},
          {3, "3d"},
          {6, "6d"},
          {7, "1w"},
          {35, "5w"},
          {59, "8w"},
          {60, "2mo"},
          {120, "4mo"},
          {-1, "today"}
        ] do
      assert TicketAge.format(Date.add(today, -days), today) == label
    end

    assert TicketAge.format(nil, today) == nil
  end
end
