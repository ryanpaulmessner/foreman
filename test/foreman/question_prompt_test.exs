defmodule Foreman.QuestionPromptTest do
  use ExUnit.Case, async: true
  alias Foreman.QuestionPrompt

  @question %{
    "question" => "Which database should the build use for local development?",
    "options" => ["Postgres", "SQLite"],
    "multi" => false
  }

  @prompt """
  ────────────────────────────────────────
   ☐ DB

  Which database should the build use for
  local development?

  ❯ 1. Postgres
       Durable
    2. SQLite
       Small
    3. Type something.
  ────────────────────────────────────────
    4. Chat about this

  Enter to select · ↑/↓ to navigate · Esc to cancel
  """

  test "matches the open prompt, even with the question wrapped" do
    assert QuestionPrompt.shown?(@prompt, @question)
    refute QuestionPrompt.other_focused?(@prompt, @question)
  end

  test "refuses an answered prompt, other questions and a typed free-text row" do
    answered = """
    ● User answered Claude's questions:
      ⎿  · Which database should the build use for local development? → Postgres
    """

    refute QuestionPrompt.shown?(answered, @question)
    refute QuestionPrompt.shown?(@prompt, %{@question | "options" => ["Postgres", "MySQL"]})
    refute QuestionPrompt.shown?(@prompt, %{@question | "question" => "Which cache?"})

    refute QuestionPrompt.shown?(
             String.replace(@prompt, "Type something.", "use both"),
             @question
           )
  end

  test "sees the pointer move to the free-text row" do
    focused =
      @prompt
      |> String.replace("❯ 1. Postgres", "  1. Postgres")
      |> String.replace("  3. Type something.", "❯ 3. Type something.")

    assert QuestionPrompt.other_focused?(focused, @question)
  end

  test "keys: a digit per option; the free-text row as digit, text and Enter" do
    assert QuestionPrompt.keys(@question, {:option, 1}) == {:ok, [{:literal, "2"}]}
    assert {:error, _} = QuestionPrompt.keys(@question, {:option, 2})

    assert QuestionPrompt.keys(@question, {:other, " both\nplease "}) ==
             {:ok, [{:literal, "3"}, :focus, {:literal, "both please"}, :enter]}

    assert {:error, :answer_required} = QuestionPrompt.keys(@question, {:other, " \n "})
  end
end
