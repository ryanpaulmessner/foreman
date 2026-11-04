defmodule Foreman.CardFooterPanelTest do
  use ExUnit.Case, async: true
  alias Foreman.CardFooterPanel, as: Panel

  @panels [:ask, :wrong_question, :withdraw]
  @states [:none | @panels]

  test "starts with no panel open" do
    assert Panel.__fsm__(:initial) == :none
  end

  test "P1: a toggle leaves at most one panel open, in place of any other" do
    for from <- @states, panel <- @panels do
      {to, _} = Panel.step(from, {:toggle, panel}, %{})
      assert to in @states
      assert to == if(from == panel, do: :none, else: panel)
    end
  end

  test "P2: every toggle that opens a panel scrolls the card to the top, and only those" do
    for from <- @states, panel <- @panels do
      {to, effects} = Panel.step(from, {:toggle, panel}, %{})

      if to == :none,
        do: assert(effects == []),
        else: assert(effects == [scroll_to_top: :card])
    end
  end

  test "card_closed closes any panel and keeps the panel text" do
    for from <- @states do
      assert Panel.step(from, :card_closed, %{}) == {:none, []}
    end
  end

  test "a sent question closes the Ask panel and clears only its text" do
    assert Panel.step(:ask, :question_sent, %{}) == {:none, [clear_text: :ask]}

    for from <- [:none, :wrong_question, :withdraw] do
      assert Panel.step(from, :question_sent, %{}) == {from, []}
    end
  end

  test "an unknown panel is refused" do
    assert {:error, {:invalid, :none, {:toggle, :other}}} =
             Panel.step(:none, {:toggle, :other}, %{})
  end

  test "panel/1 reads only the three panel names" do
    assert Panel.panel("ask") == :ask
    assert Panel.panel("wrong_question") == :wrong_question
    assert Panel.panel("withdraw") == :withdraw
    assert Panel.panel("none") == nil
    assert Panel.panel("System") == nil
  end
end
