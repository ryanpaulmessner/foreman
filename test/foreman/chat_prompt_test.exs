defmodule Foreman.ChatPromptTest do
  use ExUnit.Case, async: true
  alias Foreman.ChatPrompt

  # Layouts captured from Claude Code 2.1.303 panes (capture-pane -p -J).
  @rule String.duplicate("─", 60)

  defp screen(lines), do: Enum.join(lines, "\n") <> "\n\n\n"

  @idle Enum.join(
          [
            "⏺ Reviewed clean. Shall I commit it?",
            "",
            "✻ Worked for 1m 50s · done 2:54 PM",
            @rule,
            "❯ ",
            @rule,
            "  ⏵⏵ auto mode on (shift+tab to cycle)"
          ],
          "\n"
        ) <> "\n\n\n"

  test "an empty input box under a finished turn is the idle prompt" do
    assert ChatPrompt.idle?(@idle)
    assert ChatPrompt.idle?(String.replace(@idle, "❯ ", ">"))

    recap =
      screen([
        "✻ Worked for 1m 50s · done 2:54 PM",
        "※ recap: We pruned the backlog. Next, tell me which proposals stay.",
        "  (disable recaps in /config)",
        @rule,
        "❯",
        @rule,
        "  ⏵⏵ auto mode on (shift+tab to cycle)",
        "  2 background tasks"
      ])

    assert ChatPrompt.idle?(recap)
  end

  test "a working session is not idle, even with its input box drawn" do
    busy =
      screen([
        "  ⎿  Allowed by auto mode classifier",
        "✳ Concocting… (20s · ↓ 1.3k tokens · thought for 2s)",
        @rule,
        "❯ ",
        @rule,
        "  ⏵⏵ auto mode on · 4 shells · ⧉ 2 · esc to interrupt · ↓ to manage"
      ])

    refute ChatPrompt.idle?(busy)

    # A narrow pane cuts the footer; the spinner line still shows the turn running.
    narrow =
      screen([
        "✶ Baking… (3s)",
        "  ⎿  Tip: press ctrl+o",
        "──────────────",
        "❯ ",
        "──────────────",
        "  ⏵⏵ auto mode on (shift+tab"
      ])

    refute ChatPrompt.idle?(narrow)
  end

  test "a draft in the input box is never typed over" do
    refute ChatPrompt.idle?(String.replace(@idle, "❯ ", "❯ commit it and fix the nit"))

    multi =
      screen(["✻ Worked for 2s", @rule, "❯ first line", "  second line", @rule, "  footer"])

    refute ChatPrompt.idle?(multi)
  end

  test "a dialog or a screen without the input box is not the prompt" do
    permission =
      screen([
        "Bash command",
        "  rm -rf tmp/x",
        "Do you want to proceed?",
        "❯ 1. Yes",
        "  2. No",
        "",
        "Esc to cancel"
      ])

    refute ChatPrompt.idle?(permission)
    refute ChatPrompt.idle?("")
    refute ChatPrompt.idle?("$ ")
    refute ChatPrompt.idle?(@idle <> "some later output\nmore\nmore\nmore\nmore\n")
  end

  test "a reply is the text, then Enter, with control characters made spaces" do
    assert ChatPrompt.keys("yes, commit it") == {:ok, [{:literal, "yes, commit it"}, :enter]}
    assert ChatPrompt.keys("  a\nb\e[2J ") == {:ok, [{:literal, "a b [2J"}, :enter]}

    for bad <- ["", "  \n ", String.duplicate("x", 2_001), nil] do
      assert ChatPrompt.keys(bad) == {:error, :answer_required}
    end
  end
end
