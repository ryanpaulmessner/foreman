defmodule Foreman.StandingAnswersTest do
  use Foreman.DataCase, async: false
  alias Foreman.{Requests, Overlay}

  setup do
    Overlay.backfill(
      "sample",
      for(id <- ["s-1", "s-2"], do: %{bead_id: id, status: "open", issue_type: "task"})
    )

    :ok
  end

  defp ask(id, question \\ "Should we bypass login for previews?") do
    Requests.ask({"sample", id}, "decision", %{
      "facts" =>
        Foreman.DecisionFacts.valid(%{"question" => question, "options" => ["Yes", "No"]})
    })
  end

  test "Always is repository scoped and ordinary answers are not standing answers" do
    {:ok, first} = ask("s-1")
    {:ok, _} = Requests.resolve(first.id, :answer, %{"answer" => "No"})
    assert Foreman.Answers.standing() == []
    {:ok, second} = ask("s-2")
    {:ok, _} = Requests.resolve(second.id, :answer, %{"answer" => "No", "always" => true})
    Overlay.backfill("other", [%{bead_id: "o-1", status: "open", issue_type: "task"}])

    assert {:ok, independent} =
             Requests.ask({"other", "o-1"}, "decision", %{"facts" => first.facts})

    refute independent.standing_answer
  end

  test "two existing cards marked Always update one stored answer" do
    {:ok, first} = ask("s-1")
    {:ok, second} = ask("s-2")
    {:ok, _} = Requests.resolve(first.id, :answer, %{"answer" => "No", "always" => true})
    {:ok, _} = Requests.resolve(second.id, :answer, %{"answer" => "Yes", "always" => true})
    [answer] = Foreman.Answers.standing()
    assert answer.answer == "Yes"
    assert {:error, %{standing_answer: %{answer: "Yes"}}} = ask("s-1")
  end

  test "close matches are accepted with the standing answer but other option sets are independent" do
    {:ok, request} = ask("s-1")
    {:ok, _} = Requests.resolve(request.id, :answer, %{"answer" => "No", "always" => true})
    assert {:ok, close} = ask("s-2", "Should we bypass login for all previews?")
    assert close.standing_answer.answer == "No"

    assert {:ok, different} =
             Requests.ask({"sample", "s-2"}, "decision", %{
               "facts" =>
                 Foreman.DecisionFacts.valid(%{
                   "question" => request.facts["question"],
                   "options" => ["Cancel", "Delay"]
                 })
             })

    refute different.standing_answer
  end

  test "Always refuses an exact repeat on another ticket with the stored answer" do
    {:ok, request} = ask("s-1")

    assert {:ok, _} =
             Requests.resolve(request.id, :answer, %{
               "answer" => "No",
               "always" => true,
               "note" => "Keep login"
             })

    assert {:error, %{error: "already_answered", standing_answer: answer}} =
             ask("s-2", " SHOULD we bypass login for previews! ")

    assert answer.answer == "No"
    assert answer.note == "Keep login"
    assert Requests.pending_count() == 0
  end
end
