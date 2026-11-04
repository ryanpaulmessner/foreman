defmodule ForemanWeb.CardLinesTest do
  # The copy of the card list lines (question cards spec, Decisions 30-32).
  use ExUnit.Case, async: true
  alias ForemanWeb.CardLines

  defp request(attrs),
    do:
      struct(
        %Foreman.Requests.Request{id: "r-1", kind: "decision", facts: %{}, state: "pending"},
        attrs
      )

  describe "closed elsewhere outcome (Decision 31)" do
    for {kind, state, words} <- [
          {"decision", "answered", "Answered"},
          {"decision", "declined", "Declined"},
          {"decision", "wrong_question", "Sent as wrong question"},
          {"chore", "done", "Marked done"},
          {"push", "approved", "Approved"},
          {"push", "executing", "Approved"},
          {"push", "done", "Approved"},
          {"open_pr", "failed", "Approved"},
          {"decision", "withdrawn", "Withdrawn by the agent"},
          {"push", "superseded", "Replaced because its facts changed"}
        ] do
      test "#{kind} #{state} reads #{words}" do
        info =
          CardLines.closed_info("r-1", request(kind: unquote(kind), state: unquote(state)), "")

        assert info.outcome == unquote(words)
        assert info.note == nil
      end
    end

    test "a typed note is kept for the copy field" do
      assert CardLines.closed_info("r-1", request(state: "answered"), "Mine").note == "Mine"
    end

    test "a card that is gone has no outcome" do
      assert %{outcome: nil, at: nil} = CardLines.closed_info("r-1", nil, "")
    end
  end

  describe "result line (Decision 30)" do
    @unknown %{state: :unknown}

    test "leads by action" do
      for {action, req, params, lead} <- [
            {"answer", request([]), %{"decision" => %{"choice" => "B"}}, "Answered: B."},
            {"answer", request([]), %{"decision" => %{"choice" => "", "note" => "n"}},
             "Answered with your note."},
            {"batch-answer", request(kind: "batch", facts: %{"items" => [%{}, %{}, %{}]}),
             %{"batch" => %{"items" => ["a"]}}, "Answered: 1 of 3 items."},
            {"approve", request(kind: "push"), %{}, "Approved: Push."},
            {"approve", request(kind: "open_pr"), %{}, "Approved: Open PR."},
            {"complete", request(kind: "chore"), %{}, "Marked done."},
            {"decline", request([]), %{}, "Declined."},
            {"wrong-question", request([]), %{}, "Sent as wrong question."},
            {"withdraw", request([]), %{}, "Withdrawn."},
            {"reply", request(kind: "session_waiting"), %{"reply" => %{"text" => "yes"}},
             "Replied: yes."},
            {"reply",
             request(
               kind: "session_waiting",
               facts: %{"questions" => [%{"options" => ["X", "Y"]}]}
             ), %{"reply" => %{"choice" => "1"}}, "Replied: Y."}
          ] do
        assert CardLines.result_info(action, req, params, @unknown).lead == lead
      end
    end

    test "the receiver sentence by source" do
      req = request([])

      assert %{before: "Sent to build ", after: "."} =
               CardLines.result_info("decline", req, %{}, %{state: :live, name: "build"})

      assert %{before: "Saved ", after: ". The session that asked has ended" <> _} =
               CardLines.result_info("decline", req, %{}, %{state: :ended, name: "b"})

      assert %{before: "Saved ", after: ". The board does not know which session asked" <> _} =
               CardLines.result_info("decline", req, %{}, @unknown)

      assert %{before: nil, after: "The board starts it now."} =
               CardLines.result_info("approve", request(kind: "push"), %{}, @unknown)
    end
  end

  test "error line sentences (Decision 32)" do
    assert %{
             lead: "The card was not withdrawn.",
             reason: "The board could not save it: only a card from an agent can be withdrawn.",
             kept: "Your choice and note are still here."
           } = CardLines.error_info("r-1", "withdraw", :forbidden, "decision", %{})

    assert %{lead: "Done was not saved.", reason: "The board could not save it.", kept: nil} =
             CardLines.error_info("r-1", "complete", :boom, "chore", %{})
  end
end
