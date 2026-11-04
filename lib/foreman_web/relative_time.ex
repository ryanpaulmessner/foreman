defmodule ForemanWeb.RelativeTime do
  @moduledoc "Compact relative UTC timestamps for board status labels."
  def format(time, now \\ DateTime.utc_now()) do
    case span(time, now) do
      nil -> "just now"
      span -> span <> " ago"
    end
  end

  @doc "How long since `time`, for lines such as `for 5 min`."
  def duration(time, now \\ DateTime.utc_now()), do: span(time, now) || "under 1 min"

  @doc "How long until `time`, for lines such as `resets in 2 h`."
  def until(time, now \\ DateTime.utc_now()) do
    case span(now, time) do
      nil -> "now"
      span -> "in " <> span
    end
  end

  defp span(from, to) do
    seconds = max(DateTime.diff(to, from), 0)

    cond do
      seconds < 60 -> nil
      seconds < 3600 -> "#{div(seconds, 60)} min"
      seconds < 86400 -> "#{div(seconds, 3600)} h"
      true -> "#{div(seconds, 86400)} d"
    end
  end
end
