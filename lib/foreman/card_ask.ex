defmodule Foreman.CardAsk do
  @moduledoc """
  Ask on an open card (question cards spec, Decision 40, as changed by Ryan on
  2026-11-04, cards 602ad7c1 and 8ff81918). The card has one text box; Ask sends
  its text to the asking session as a question and the card stays open.

  - `idle`: nothing to show under the footer.
  - `copy`: the board cannot send to the source (unknown, or ended until the
    Sessions work ships), so the card shows the hint and the copy field.
  - `failed`: the send failed; the card shows the reason, Try again and the copy
    field.

  The text belongs to the card. Only `sent` clears it (`clear_text`).
  """
  use Foreman.Fsm
  initial(:idle)
  state(:idle)
  state(:copy)
  state(:failed)
  event(:sent, source: :observed)
  event(:unsendable, source: :observed)
  event(:failed, source: :observed)
  event(:card_closed)
  effects([:clear_text])
  transition(:sent, from: :any, to: :idle, do: [clear_text: :card])
  transition(:unsendable, from: :any, to: :copy)
  transition(:failed, from: :any, to: :failed)
  transition(:card_closed, from: :any, to: :idle)
end
