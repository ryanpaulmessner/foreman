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

  test "image filenames in either question or text require a review_ui card" do
    for field <- ["question", "text"], extension <- ~w(png jpg jpeg gif webp PNG) do
      facts = Foreman.DecisionFacts.valid(%{"question" => "Which?"})
      facts = Map.update!(facts, field, &(&1 <> " See shots/layout." <> extension))

      assert {:error, %{error: "card_unclear", missing: [message]}} =
               Requests.ask({"sample", "s-1"}, "decision", %{"facts" => facts})

      assert message ==
               "screenshots go on a review_ui card: foreman ask review_ui <ticket> --image <file-or-folder>"
    end

    assert Requests.pending_count() == 0
  end

  test "verify run paths in either field require a review_ui card" do
    for field <- ["question", "text"],
        path <- ["~/.cache/verify/runs/check", "/tmp/test/.cache/verify/runs/check"] do
      facts = Foreman.DecisionFacts.valid(%{"question" => "Which?"})
      facts = Map.update!(facts, field, &(&1 <> " See " <> path))

      assert {:error, %{error: "card_unclear", missing: [_]}} =
               Requests.ask({"sample", "s-1"}, "decision", %{"facts" => facts})
    end
  end

  test "visual judgment questions without docs require a review_ui card" do
    for subject <- ["screenshots", "mockup"],
        judgment <- ["look right", "LOOK GOOD"],
        docs <- [nil, []] do
      facts =
        Foreman.DecisionFacts.valid(%{
          "question" => "Does this #{subject} #{judgment}?",
          "docs" => docs
        })

      assert {:error, %{error: "card_unclear", missing: [_]}} =
               Requests.ask({"sample", "s-1"}, "decision", %{"facts" => facts})
    end
  end

  test "a mockup document permits a visual judgment decision but not image paths" do
    root = Foreman.ScratchDocs.dir("decision-lint")
    Foreman.ScratchDocs.write(root, %{"mockup.md" => "# Design pack"})
    Foreman.ScratchDocs.configure(%{"sample" => root})
    on_exit(fn -> File.rm_rf!(root) end)

    facts =
      Foreman.DecisionFacts.valid(%{
        "question" => "Does the mockup look right?",
        "docs" => ["mockup.md"]
      })

    assert {:ok, request} = Requests.ask({"sample", "s-1"}, "decision", %{"facts" => facts})
    assert request.facts["docs"] == [%{"repo" => "sample", "path" => "mockup.md"}]

    assert {:error, %{error: "card_unclear"}} =
             Requests.ask({"sample", "s-1"}, "decision", %{
               "facts" => Map.put(facts, "question", "Use mockup.png?")
             })
  end

  test "normal decisions and passing screenshot mentions remain valid" do
    for question <- [
          "Which storage backend?",
          "Should we automate screenshot capture?",
          "Does the schedule look good?"
        ] do
      facts = Foreman.DecisionFacts.valid(%{"question" => question})

      facts =
        Map.update!(
          facts,
          "text",
          &(&1 <> "\nThe screenshots look good; capture is already covered.")
        )

      assert {:ok, %{state: "pending"}} =
               Requests.ask({"sample", "s-1"}, "decision", %{"facts" => facts})
    end
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
