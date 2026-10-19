defmodule Foreman.ChatQuestionTest do
  use ExUnit.Case, async: true
  alias Foreman.ChatQuestion

  describe "question/1" do
    test "a trailing question mark in the last paragraph is a question" do
      text = "I ran the suite; all green.\n\nPush slice 31 now, browser check first, or hold?"

      assert ChatQuestion.question(text) ==
               {:ok, "Push slice 31 now, browser check first, or hold?"}
    end

    test "trailing markdown after the question mark still counts" do
      assert {:ok, _} = ChatQuestion.question("Done.\n\n**Shall we ship it?**")
      assert {:ok, _} = ChatQuestion.question("Ready to merge (base is green)?)")
    end

    test "ask phrases count without a question mark" do
      for ask <- [
            "Reviewed clean. Shall I commit it on feat/x? I recommend committing.",
            "Should I open the PR now. I can also wait.",
            "Do you want the screenshots too. They take a minute.",
            "Would you like me to drop the scratch database.",
            "Want me to file a ticket for the flake.",
            ~s(Say "go" and I will push.),
            "Say `ship it` when ready."
          ] do
        assert {:ok, ^ask} = ChatQuestion.question("Summary line.\n\n" <> ask), ask
      end
    end

    test "a closing list of options belongs to the question before it" do
      text = "Work is done.\n\nWhich next?\n- Commit now, live check later.\n- Hold."

      assert ChatQuestion.question(text) ==
               {:ok, "Which next?\n- Commit now, live check later.\n- Hold."}

      text = "Done.\n\nShall I commit?\n\n1. Commit now\n   (recommended)\n2. Hold"

      assert ChatQuestion.question(text) ==
               {:ok, "Shall I commit?\n\n1. Commit now\n   (recommended)\n2. Hold"}

      assert ChatQuestion.question("Changes:\n\n- added a test\n- fixed a typo") == :none
    end

    test "statements, earlier questions and empty text are not questions" do
      for text <- [
            "Committed abc123. All tests pass.",
            "Shall I commit?\n\nCommitted anyway; nothing left.",
            "The `ok?` predicate now returns false.",
            "Why did it fail? A stale lock. Fixed and pushed.",
            "",
            "   \n\n  ",
            nil
          ] do
        assert ChatQuestion.question(text) == :none, inspect(text)
      end
    end

    test "the stored text is capped, keeping the end where the question is" do
      long = String.duplicate("word ", 400) <> "ready to ship?"
      assert {:ok, text} = ChatQuestion.question(long)
      assert String.length(text) == 1_000
      assert String.starts_with?(text, "…")
      assert String.ends_with?(text, "ready to ship?")
    end
  end

  describe "last_message/1" do
    test "prefers the hook's last_assistant_message" do
      assert ChatQuestion.last_message(%{
               "last_assistant_message" => "Shall I?",
               "transcript_path" => "/nonexistent"
             }) == "Shall I?"
    end

    @tag :tmp_dir
    test "falls back to the transcript's last main-thread assistant text", %{tmp_dir: dir} do
      path = Path.join(dir, "t.jsonl")

      write(path, [
        %{"type" => "user", "message" => %{"role" => "user", "content" => "do it"}},
        assistant([%{"type" => "text", "text" => "Earlier words."}]),
        assistant([%{"type" => "tool_use", "id" => "t1", "name" => "Bash", "input" => %{}}]),
        %{
          "type" => "user",
          "message" => %{"role" => "user", "content" => [%{"type" => "tool_result"}]}
        },
        assistant([%{"type" => "thinking", "thinking" => "hmm"}]),
        assistant([
          %{"type" => "text", "text" => "All green."},
          %{"type" => "text", "text" => "Shall I commit?"}
        ]),
        Map.put(
          assistant([%{"type" => "text", "text" => "sidechain words?"}]),
          "isSidechain",
          true
        ),
        %{
          "type" => "api-request-blob",
          "message" => %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "blob?"}]
          }
        },
        %{"type" => "last-prompt"}
      ])

      assert ChatQuestion.last_message(%{"transcript_path" => path}) ==
               "All green.\n\nShall I commit?"
    end

    @tag :tmp_dir
    test "a user prompt after the last assistant text means there is no message", %{tmp_dir: dir} do
      path = Path.join(dir, "t.jsonl")

      write(path, [
        assistant([%{"type" => "text", "text" => "Shall I commit?"}]),
        %{"type" => "user", "message" => %{"role" => "user", "content" => "yes"}}
      ])

      assert ChatQuestion.last_message(%{"transcript_path" => path}) == nil
    end

    @tag :tmp_dir
    test "only the transcript's tail is read; a missing or odd file gives nil", %{tmp_dir: dir} do
      path = Path.join(dir, "t.jsonl")
      big = String.duplicate("x", 300_000)

      write(path, [
        assistant([%{"type" => "text", "text" => "Old question?"}]),
        assistant([%{"type" => "text", "text" => big}]),
        %{"type" => "system"}
      ])

      # The last assistant line is cut by the tail window; the old one is not reached.
      assert ChatQuestion.last_message(%{"transcript_path" => path}) == nil
      assert ChatQuestion.last_message(%{"transcript_path" => Path.join(dir, "none")}) == nil
      assert ChatQuestion.last_message(%{"transcript_path" => dir}) == nil
      assert ChatQuestion.last_message(%{"transcript_path" => 7}) == nil
      assert ChatQuestion.last_message(%{}) == nil
    end
  end

  defp assistant(content),
    do: %{"type" => "assistant", "message" => %{"role" => "assistant", "content" => content}}

  defp write(path, entries),
    do: File.write!(path, Enum.map_join(entries, "", &(Jason.encode!(&1) <> "\n")))
end
