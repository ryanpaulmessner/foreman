defmodule Foreman.CardListTest do
  # The card list on Needs you (question cards spec, Decision 39, rules R1-R9).
  use ExUnit.Case, async: true
  alias Foreman.CardList

  defp loaded(ids, opts \\ []), do: CardList.loaded(CardList.new(), ids, opts)

  defp open(ids, id) do
    {list, _} = loaded(ids)
    {list, _} = CardList.open_row(list, id)
    list
  end

  defp closed_info(id), do: {:closed_info, id}

  describe "first load" do
    test "opens the first card when no card is asked for" do
      assert {%{state: :open, open: "a", order: ["a", "b"], notice: nil}, []} =
               loaded(["a", "b"])
    end

    test "opens the card the URL names" do
      assert {%{state: :open, open: "b"}, []} = loaded(["a", "b"], want: "b")
    end

    test "a stale card link opens the first card and shows the stale line" do
      assert {%{state: :open, open: "a", notice: :stale}, []} = loaded(["a", "b"], want: "gone")
    end

    test "nothing pending shows the empty list" do
      assert {%{state: :empty, open: nil, order: []}, []} = loaded([])
    end

    test "a stale card link on an empty list still says why" do
      assert {%{state: :empty, notice: :stale}, []} = loaded([], want: "gone")
    end

    test "a failed first load keeps the loading state and shows the error" do
      assert {%{state: :loading, load_error: true}, []} = CardList.load_failed(CardList.new())
    end
  end

  describe "polls (R2)" do
    test "a new card joins as a row and never moves the open card" do
      list = open(["a", "b"], "b")
      {list, fx} = CardList.loaded(list, ["new", "a", "b"])
      assert %{state: :open, open: "b", order: ["new", "a", "b"]} = list
      assert fx == []
    end

    test "a poll keeps a failed card failed with its error line" do
      list = open(["a", "b"], "a")
      {list, _} = CardList.resolve_failed(list, "a", :boom)
      {list, _} = CardList.loaded(list, ["a", "b", "c"])
      assert %{state: :failed, open: "a", error: :boom} = list
    end

    test "with the list closed, new cards are rows and none opens" do
      {list, _} = CardList.close(open(["a"], "a"))

      assert {%{state: :closed, open: nil, order: ["a", "b"]}, []} =
               CardList.loaded(list, ["a", "b"])
    end

    test "the list closed and every card gone is empty" do
      {list, _} = CardList.close(open(["a"], "a"))
      assert {%{state: :empty}, []} = CardList.loaded(list, [])
    end

    test "on an empty list a new card opens (Decision 9)" do
      {list, _} = loaded([])
      assert {%{state: :open, open: "n"}, []} = CardList.loaded(list, ["n"])
    end

    test "a failed load keeps the rows and the open card" do
      list = open(["a", "b"], "b")
      {list, []} = CardList.load_failed(list)
      assert %{state: :open, open: "b", order: ["a", "b"], load_error: true} = list
      {list, []} = CardList.loaded(list, ["a", "b"])
      refute list.load_error
    end
  end

  describe "closed elsewhere (R6, Decision 10)" do
    test "the open card leaving shows its line in its place and opens the row under it" do
      list = open(["a", "b", "c"], "b")
      {list, fx} = CardList.loaded(list, ["a", "c"], closed: &closed_info/1)
      assert %{state: :open, open: "c", order: ["a", "b", "c"]} = list
      assert list.lines == %{"b" => {:closed, {:closed_info, "b"}}}
      assert fx == []
    end

    test "the last row leaving opens the first row" do
      list = open(["a", "b"], "b")
      {list, _} = CardList.loaded(list, ["a"], closed: &closed_info/1)
      assert %{open: "a", order: ["a", "b"]} = list
    end

    test "the only card leaving shows its line and the empty list" do
      list = open(["a"], "a")
      {list, _} = CardList.loaded(list, [], closed: &closed_info/1)
      assert %{state: :empty, open: nil, order: ["a"]} = list
      assert %{"a" => {:closed, _}} = list.lines
    end

    test "a failed card closing elsewhere clears its error line" do
      list = open(["a", "b"], "a")
      {list, _} = CardList.resolve_failed(list, "a", :boom)
      {list, _} = CardList.loaded(list, ["b"], closed: &closed_info/1)
      assert %{state: :open, open: "b", error: nil} = list
    end

    test "the closed line stays until your next action, or its X" do
      list = open(["a", "b", "c"], "a")
      {list, _} = CardList.loaded(list, ["b", "c"], closed: &closed_info/1)
      {list, _} = CardList.loaded(list, ["b", "c"])
      assert Map.has_key?(list.lines, "a")
      {gone, _} = CardList.open_row(list, "c")
      assert gone.lines == %{}
      assert gone.order == ["b", "c"]
      {dismissed, []} = CardList.dismiss_line(list, "a")
      assert dismissed.lines == %{}
      assert dismissed.order == ["b", "c"]
    end
  end

  describe "opening a row (R1, R3)" do
    test "opening a row closes the other and keeps its input" do
      list = open(["a", "b"], "a")
      assert {%{state: :open, open: "b"}, [card_closed: "a"]} = CardList.open_row(list, "b")
    end

    test "opening a row from the closed list" do
      {list, _} = CardList.close(open(["a", "b"], "a"))
      assert {%{state: :open, open: "b"}, []} = CardList.open_row(list, "b")
    end

    test "opening the open card again changes nothing" do
      list = open(["a", "b"], "a")
      assert {^list, []} = CardList.open_row(list, "a")
    end

    test "a card that is not pending shows the stale line and keeps the open card" do
      list = open(["a", "b"], "b")
      assert {%{state: :open, open: "b", notice: :stale}, []} = CardList.open_row(list, "gone")
    end

    test "the stale line goes with your next action" do
      list = open(["a", "b"], "b")
      {list, _} = CardList.open_row(list, "gone")
      assert {%{notice: nil}, _} = CardList.open_row(list, "a")
    end

    test "opening another row clears the failed card's error line (R9)" do
      list = open(["a", "b"], "a")
      {list, _} = CardList.resolve_failed(list, "a", :boom)

      assert {%{state: :open, open: "b", error: nil}, [card_closed: "a"]} =
               CardList.open_row(list, "b")
    end
  end

  describe "close" do
    test "Close card leaves every card a row and keeps the input" do
      list = open(["a", "b"], "a")

      assert {%{state: :closed, open: nil, order: ["a", "b"]}, [card_closed: "a"]} =
               CardList.close(list)
    end

    test "Close card on a failed card clears its error line" do
      list = open(["a"], "a")
      {list, _} = CardList.resolve_failed(list, "a", :boom)
      assert {%{state: :closed, error: nil}, _} = CardList.close(list)
    end
  end

  describe "after you act (R4, R5, R8)" do
    test "the result line takes the card's place and the row under it opens" do
      list = open(["a", "b", "c"], "b")
      {list, fx} = CardList.resolved(list, "b", ["a", "c"], :sent)
      assert %{state: :open, open: "c", order: ["a", "b", "c"]} = list
      assert list.lines == %{"b" => {:result, :sent}}
      assert fx == [expire: "b", drop_input: "b"]
    end

    test "the last row resolved opens the first" do
      list = open(["a", "b"], "b")
      assert {%{open: "a"}, _} = CardList.resolved(list, "b", ["a"], :sent)
    end

    test "next is taken from the list at the time of the result" do
      list = open(["a", "b", "c"], "a")
      # b left before the poll; a card arrived at the top.
      {list, _} = CardList.resolved(list, "a", ["new", "c"], :sent)
      assert %{open: "c", order: ["a", "new", "c"]} = list
    end

    test "the last card resolved shows the result line over the empty list (R7)" do
      list = open(["a"], "a")
      {list, _} = CardList.resolved(list, "a", [], :sent)
      assert %{state: :empty, open: nil, order: ["a"], lines: %{"a" => {:result, :sent}}} = list
    end

    test "the result line goes after its timer" do
      list = open(["a", "b"], "a")
      {list, _} = CardList.resolved(list, "a", ["b"], :sent)
      {list, []} = CardList.line_expired(list, "a")
      assert %{lines: lines, order: ["b"], open: "b"} = list
      assert lines == %{}
    end

    test "a poll keeps the result line in its place" do
      list = open(["a", "b", "c"], "b")
      {list, _} = CardList.resolved(list, "b", ["a", "c"], :sent)
      {list, _} = CardList.loaded(list, ["a", "c", "d"])
      assert list.order == ["a", "b", "c", "d"]
    end

    test "a failed action keeps the card open with the error line" do
      list = open(["a", "b"], "a")

      assert {%{state: :failed, open: "a", error: :boom}, []} =
               CardList.resolve_failed(list, "a", :boom)
    end

    test "the error line stays until your next action on the card" do
      list = open(["a", "b"], "a")
      {list, _} = CardList.resolve_failed(list, "a", :boom)
      {list, _} = CardList.resolve_failed(list, "a", :again)
      assert %{state: :failed, error: :again} = list
      {list, _} = CardList.resolved(list, "a", ["b"], :sent)
      assert %{state: :open, open: "b", error: nil} = list
    end

    test "acting is refused when no card is open" do
      {list, _} = CardList.close(open(["a"], "a"))
      assert {^list, []} = CardList.resolved(list, "a", [], :sent)
      assert {^list, []} = CardList.resolve_failed(list, "a", :boom)
    end
  end

  test "the machine has a generated docs page with every state" do
    doc = Foreman.Fsm.Renderer.document(CardList, "card_list")
    for state <- ~w(loading empty closed open failed), do: assert(doc =~ state)
  end
end
