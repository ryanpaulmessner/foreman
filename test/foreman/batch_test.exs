defmodule Foreman.BatchTest do
  use Foreman.DataCase, async: false
  alias Foreman.{Requests, Overlay, Repo}

  setup do
    Overlay.backfill("sample", [%{bead_id: "s-1", status: "open", issue_type: "task"}])
    :ok
  end

  defp facts do
    %{
      "question" => "File tickets?",
      "text" => "What: Findings\nPart of: Sweep\nWhy now: Review complete",
      "items" => [
        %{"id" => "a", "label" => "First"},
        %{"id" => "b", "label" => "Second", "detail" => "Fix the timeout"}
      ]
    }
  end

  test "CLI preserves ordered items and their optional details" do
    assert {:ok, %{request: r}} =
             Foreman.CLI.parse([
               "ask",
               "batch",
               "s-1",
               "--question",
               "File tickets?",
               "--text",
               facts()["text"],
               "--item",
               "a=First",
               "--item",
               "b=Second",
               "--item-detail",
               "b=Fix the timeout"
             ])

    assert r["facts"]["items"] == facts()["items"]
    assert {:error, _} = Foreman.CLI.parse(["ask", "batch", "s-1", "--item", "bad"])

    assert {:error, _} =
             Foreman.CLI.parse([
               "ask",
               "batch",
               "s-1",
               "--item",
               "a=First",
               "--item-detail",
               "missing=Detail"
             ])
  end

  test "batch validates size, unique ids, labels, context and checked ids" do
    for items <- [
          [],
          [hd(facts()["items"])],
          List.duplicate(hd(facts()["items"]), 2),
          [%{"id" => "a", "label" => ""}, %{"id" => "b", "label" => "B"}],
          Enum.map(1..51, &%{"id" => to_string(&1), "label" => "Item"})
        ] do
      assert {:error, :invalid_facts} =
               Requests.ask({"sample", "s-1"}, "batch", %{
                 "facts" => Map.put(facts(), "items", items)
               })
    end

    assert {:error, %{error: "card_unclear"}} =
             Requests.ask({"sample", "s-1"}, "batch", %{"facts" => Map.delete(facts(), "text")})

    assert {:ok, r} = Requests.ask({"sample", "s-1"}, "batch", %{"facts" => facts()})

    for answer <- [["unknown"], ["a", "a"], "a", nil] do
      assert {:error, :invalid} = Requests.resolve(r.id, :answer, %{"answer" => answer})
      assert Requests.get(r.id).state == "pending"
    end

    assert {:ok, wrong} =
             Requests.resolve(r.id, :wrong_question, %{"note" => "These are already filed"})

    assert wrong.state == "wrong_question"
  end

  test "one batch records checked ids, including an empty selection, without executing work" do
    for answer <- [["b"], []] do
      assert {:ok, request} = Requests.ask({"sample", "s-1"}, "batch", %{"facts" => facts()})
      assert request.facts["items"] == facts()["items"]
      assert {:error, :invalid} = Requests.resolve(request.id, :approve, %{})
      assert {:ok, done} = Requests.resolve(request.id, :answer, %{"answer" => answer})
      assert done.state == "answered"
      assert done.outcome == %{"answer" => answer}

      assert {200, wire} =
               Foreman.AgentCommands.execute(%{"action" => "wait", "id" => request.id})

      assert wire["outcome"] == %{"answer" => answer}
    end

    assert Repo.aggregate(Oban.Job, :count) == 0
  end
end
