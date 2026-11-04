defmodule Foreman.CardContextTest do
  use ExUnit.Case, async: true
  alias Foreman.CardContext

  test "plain labels, one per line" do
    assert %{what: "Layout", part_of: "Cards", why_now: "Review", from: nil, notes: nil} =
             CardContext.parse("What: Layout\nPart of: Cards\nWhy now: Review")
  end

  test "bold labels, labels in any case, and notes after a blank line" do
    text =
      "**What:** the page every session link opens (`/sessions/:id`).\n" <>
        "**part of:** fm-9mm, Sessions\n" <>
        "**From:** docs/specs/sessions-view.md\n" <>
        "WHY NOW: the build waits on this pick.\n\n" <>
        "The mockups are in the sessions-view folder.\n\nI compared all three."

    assert CardContext.parse(text) == %{
             what: "the page every session link opens (`/sessions/:id`).",
             why_now: "the build waits on this pick.",
             part_of: "fm-9mm, Sessions",
             from: "docs/specs/sessions-view.md",
             notes: "The mockups are in the sessions-view folder.\n\nI compared all three."
           }
  end

  test "a value runs over lines to the next labelled line or the next blank line" do
    text = "What: first line\nsecond line\nWhy now: soon\n\nnote"

    assert %{what: "first line\nsecond line", why_now: "soon", notes: "note"} =
             CardContext.parse(text)
  end

  test "notes before the labels stay notes; From is optional" do
    assert %{what: "A", why_now: "B", from: nil, part_of: nil, notes: "Intro line."} =
             CardContext.parse("Intro line.\n\nWhat: A\nWhy now: B")
  end

  test "only Why now still makes a list" do
    assert %{what: nil, why_now: "B"} = CardContext.parse("Why now: B")
  end

  test "text with no What and no Why now gives no list" do
    assert CardContext.parse("Part of: Cards\nFrom: chat\nJust some text") == nil
    assert CardContext.parse("What happens: nothing") == nil
    assert CardContext.parse("") == nil
    assert CardContext.parse(nil) == nil
  end

  test "an empty labelled value counts as missing" do
    assert CardContext.parse("What:\nWhy now:\n") == nil
  end

  test "it finds a label exactly when the ask lint does" do
    texts = [
      "What: a\nPart of: b\nWhy now: c",
      "**What:** a\n**Part of:** b\n**Why now:** c",
      "  what : a",
      "**What**: a",
      "Whatever: a",
      "x What: a",
      "line\n  **WHY NOW:** c"
    ]

    for text <- texts do
      lint =
        case Foreman.Requests.Decision.validate(
               %{"question" => "Q?", "options" => [], "text" => text},
               %{repo_key: "none"}
             ) do
          {:error, %{missing: missing}} -> missing
          {:ok, _} -> []
        end

      parsed = CardContext.parse(text) || %{}

      for {label, key} <- [{"What", :what}, {"Part of", :part_of}, {"Why now", :why_now}] do
        assert label in lint == is_nil(parsed[key]), "#{label} in #{inspect(text)}"
      end
    end
  end

  test "parts lists the More context parts that exist" do
    assert CardContext.parts(%{part_of: "a", from: nil, notes: "n"}) == ["Part of", "agent notes"]
    assert CardContext.parts(%{part_of: "a", from: "b", notes: nil}) == ["Part of", "From"]
    assert CardContext.parts(%{part_of: nil, from: nil, notes: nil}) == []
  end
end
