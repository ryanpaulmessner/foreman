defmodule Foreman.DecisionLintTest do
  use Foreman.DataCase, async: false
  alias Foreman.{AgentCommands, Overlay, Requests}

  setup do
    Overlay.backfill("sample", [%{bead_id: "s-1", status: "open", issue_type: "task"}])
    :ok
  end

  test "post refuses missing labels and each missing option detail by name" do
    assert {422,
            %{
              error: "card_unclear",
              missing: ["What", "Part of", "Why now", "option detail: A", "option detail: B"]
            }} =
             AgentCommands.execute(%{
               "repo" => "sample",
               "id" => "s-1",
               "action" => "ask",
               "request_kind" => "decision",
               "facts" => %{"question" => "Which?", "options" => ["A", "B"]}
             })

    assert Requests.pending_count() == 0
  end

  test "blank body and blank option details name the missing parts" do
    assert {:error,
            %{error: "card_unclear", missing: ["What", "Part of", "Why now", "option detail: A"]}} =
             Requests.ask({"sample", "s-1"}, "decision", %{
               "facts" => %{
                 "question" => "Which?",
                 "text" => " ",
                 "options" => ["A"],
                 "option_details" => %{"A" => " "}
               }
             })
  end

  test "labels are case insensitive and markdown labels pass" do
    assert {:ok, request} =
             Requests.ask({"sample", "s-1"}, "decision", %{
               "facts" => %{
                 "question" => "Which?",
                 "text" => "**what:** Layout\n**PART OF:** Cards\n**Why now:** Review",
                 "options" => ["A"],
                 "option_details" => %{"A" => "Use a grid"}
               }
             })

    assert request.state == "pending"
  end

  test "an existing pending card can still be answered without lint" do
    request =
      Foreman.Repo.insert!(%Foreman.Requests.Request{
        repo_key: "sample",
        bead_id: "s-1",
        actor: "pi",
        kind: "decision",
        state: "pending",
        facts: %{"question" => "Old?"}
      })

    assert {:ok, %{state: "answered"}} =
             Requests.resolve(request.id, :answer, %{"answer" => "Yes"})
  end
end
