defmodule ForemanWeb.TicketAge do
  @moduledoc "Compact ticket creation ages in UTC calendar days."
  def format(date, today \\ Date.utc_today())
  def format(nil, _today), do: nil

  def format(%Date{} = date, today) do
    days = max(Date.diff(today, date), 0)

    cond do
      days == 0 -> "today"
      days < 7 -> "#{days}d"
      days < 60 -> "#{div(days, 7)}w"
      true -> "#{div(days, 30)}mo"
    end
  end
end
