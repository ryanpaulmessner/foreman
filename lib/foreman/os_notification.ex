defmodule Foreman.OsNotification do
  @moduledoc """
  One native notification per request: posted the first time the board sees it
  pending, when notifications are enabled and the request was created after
  this node booted; otherwise skipped for good.
  """
  use Foreman.Fsm
  initial(:unseen)
  state(:unseen)
  state(:notified)
  state(:skipped)
  event(:pending, source: :observed)
  effects([:post])
  guard(:postable?)
  transition(:pending, from: :unseen, to: :notified, guard: :postable?, do: [post: :notification])
  transition(:pending, from: :unseen, to: :skipped)
  ignore(:pending, from: :any)

  def postable?(%{enabled: true, after_boot: true}, _), do: true
  def postable?(_, _), do: false
end
