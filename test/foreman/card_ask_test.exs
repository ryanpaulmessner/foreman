defmodule Foreman.CardAskTest do
  use ExUnit.Case, async: true
  alias Foreman.CardAsk

  @states [:idle, :copy, :failed]

  test "starts idle" do
    assert CardAsk.__fsm__(:initial) == :idle
  end

  test "a sent question returns to idle and clears the card text, from any state" do
    for from <- @states,
        do: assert(CardAsk.step(from, :sent, %{}) == {:idle, [clear_text: :card]})
  end

  test "a source that cannot get the question shows the copy field, keeping the text" do
    for from <- @states, do: assert(CardAsk.step(from, :unsendable, %{}) == {:copy, []})
  end

  test "a failed send shows the error line, keeping the text" do
    for from <- @states, do: assert(CardAsk.step(from, :failed, %{}) == {:failed, []})
  end

  test "card_closed returns to idle and keeps the text" do
    for from <- @states, do: assert(CardAsk.step(from, :card_closed, %{}) == {:idle, []})
  end

  test "no event clears the text except a sent question" do
    for from <- @states, event <- [:unsendable, :failed, :card_closed] do
      {_, effects} = CardAsk.step(from, event, %{})
      refute Keyword.has_key?(effects, :clear_text)
    end
  end
end
