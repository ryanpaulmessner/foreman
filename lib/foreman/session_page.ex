defmodule Foreman.SessionPage do
  @moduledoc "URL-selected session tab. Without an explicit tab, waiting and dead sessions open Timeline."
  use Foreman.Fsm
  initial(:output)
  state(:output)
  state(:timeline)
  state(:details)
  event(:params)
  guard(:details?)
  guard(:timeline?)
  transition(:params, from: :any, to: :details, guard: :details?)
  transition(:params, from: :any, to: :timeline, guard: :timeline?)
  transition(:params, from: :any, to: :output)

  def details?(_, %{tab: tab}), do: tab == "details"

  def timeline?(_, %{tab: tab, waiting: waiting, dead: dead}),
    do: tab == "timeline" or (tab != "output" and (waiting == true or dead == true))
end
