defmodule Foreman.PreviewCheck do
  @moduledoc "Reachability of a pending review's local preview, independent of Request."
  use Foreman.Fsm, observed_never_invalid: true
  initial(:unchecked)
  state(:unchecked)
  state(:up)
  state(:down)
  state(:stopped)
  event(:check_ok, source: :observed)
  event(:check_failed, source: :observed)
  event(:card_left_pending, source: :observed)
  transition(:check_ok, from: [:unchecked, :down], to: :up)
  transition(:check_failed, from: [:unchecked, :up], to: :down)
  transition(:card_left_pending, from: [:unchecked, :up, :down], to: :stopped)
  ignore([:check_ok, :check_failed, :card_left_pending], from: :any)

  def load(facts) do
    case facts["preview"] do
      "up" -> :up
      "down" -> :down
      "stopped" -> :stopped
      _ -> :unchecked
    end
  end

  def stop(%{"url" => url} = facts) when is_binary(url) do
    {state, []} = step(load(facts), :card_left_pending, %{})
    Map.put(facts, "preview", to_string(state))
  end

  def stop(facts), do: facts
end
