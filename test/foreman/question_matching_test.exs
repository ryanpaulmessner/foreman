defmodule Foreman.QuestionMatchingTest do
  use ExUnit.Case, async: true
  alias Foreman.Requests.{Questions, Request}

  test "flags only similar pending questions with the same ticket, repository and kind" do
    first = %Request{
      id: "one",
      repo_key: "sample",
      bead_id: "s-1",
      kind: "decision",
      state: "pending",
      facts: %{"question" => "Which delivery date should we use?"}
    }

    same = %{
      first
      | id: "two",
        facts: %{"question" => " WHICH delivery date should we use now! "}
    }

    unrelated = %{first | id: "three", facts: %{"question" => "Which database engine?"}}

    assert Enum.map(Questions.flag([first, same, unrelated]), & &1.similar_question) == [
             true,
             true,
             false
           ]

    for other <- [
          %{same | repo_key: "other"},
          %{same | bead_id: "s-2"},
          %{same | kind: "chore"},
          %{same | state: "answered"}
        ] do
      assert Enum.map(Questions.flag([first, other]), & &1.similar_question) == [false, false]
    end

    refute Questions.close?(nil, nil)
    refute Questions.close?("?", "!")
    assert Questions.close?("Which date?", " which   DATE! ")
  end
end
