defmodule Foreman.CardFooterPanel do
  @moduledoc """
  The open card's footer panel (question cards spec, Decision 40): `none`, or one
  of Ask about this, Wrong question and Withdraw. Each card has an instance.

  - P1: at most one panel is open. `toggle(panel)` on the open panel closes it;
    on another panel it opens that one in its place.
  - P2: opening a panel scrolls the card to the top (`scroll_to_top`).

  The panel text belongs to the card, not to the panel, so `card_closed` keeps
  it. Only `question_sent` clears text, and only the Ask text.
  """
  use Foreman.Fsm
  initial(:none)
  state(:none)
  state(:ask)
  state(:wrong_question)
  state(:withdraw)
  event(:toggle)
  event(:card_closed)
  event(:question_sent, source: :observed)
  guard(:ask?)
  guard(:wrong_question?)
  guard(:withdraw?)
  effects([:scroll_to_top, :clear_text])
  transition(:toggle, from: [:ask], to: :none, guard: :ask?)
  transition(:toggle, from: [:wrong_question], to: :none, guard: :wrong_question?)
  transition(:toggle, from: [:withdraw], to: :none, guard: :withdraw?)

  transition(:toggle,
    from: [:none, :wrong_question, :withdraw],
    to: :ask,
    guard: :ask?,
    do: [scroll_to_top: :card]
  )

  transition(:toggle,
    from: [:none, :ask, :withdraw],
    to: :wrong_question,
    guard: :wrong_question?,
    do: [scroll_to_top: :card]
  )

  transition(:toggle,
    from: [:none, :ask, :wrong_question],
    to: :withdraw,
    guard: :withdraw?,
    do: [scroll_to_top: :card]
  )

  invalid(:toggle, from: :any)
  transition(:card_closed, from: :any, to: :none)
  transition(:question_sent, from: [:ask], to: :none, do: [clear_text: :ask])
  ignore(:question_sent, from: :any)

  @panels %{"ask" => :ask, "wrong_question" => :wrong_question, "withdraw" => :withdraw}

  def ask?(_, panel), do: panel == :ask
  def wrong_question?(_, panel), do: panel == :wrong_question
  def withdraw?(_, panel), do: panel == :withdraw

  @doc "The panel a footer action names, or nil."
  def panel(name), do: Map.get(@panels, name)
end
