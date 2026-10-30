defmodule Foreman.CardUpdateTest do
  use Foreman.DataCase, async: false
  alias Foreman.{Requests, Overlay}

  setup do
    Overlay.backfill("sample", [%{bead_id: "s-1", status: "open", issue_type: "task"}])

    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "actor" => "pi",
        "session" => "build",
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Which date?"})
      })

    %{request: request}
  end

  test "docs can be replaced while an omitted doc list stays linked", %{request: r} do
    root = Foreman.ScratchDocs.dir("card-update")
    Foreman.ScratchDocs.write(root, %{"first.md" => "# First", "second.md" => "# Second"})
    Foreman.ScratchDocs.configure(%{"sample" => root})
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:ok, first} = Requests.update(r.id, "pi", "build", %{"docs" => ["first.md"]})
    assert first.facts["docs"] == [%{"repo" => "sample", "path" => "first.md"}]
    assert {:ok, same} = Requests.update(r.id, "pi", "build", %{"question" => "Changed?"})
    assert same.facts["docs"] == first.facts["docs"]
    assert {:ok, second} = Requests.update(r.id, "pi", "build", %{"docs" => ["second.md"]})
    assert second.facts["docs"] == [%{"repo" => "sample", "path" => "second.md"}]

    assert {:error, :invalid_doc} =
             Requests.update(r.id, "pi", "build", %{"docs" => ["missing.md"]})

    assert Requests.get(r.id).facts == second.facts
  end

  test "an action card can update display text but not its executable facts", %{request: r} do
    r
    |> Ecto.Changeset.change(kind: "push", facts: %{"expected_sha" => "bound-sha"})
    |> Foreman.Repo.update!()

    assert {:ok, updated} = Requests.update(r.id, "pi", "build", %{"text" => "The build passed"})
    assert updated.facts["text"] == "The build passed"
    assert updated.facts["expected_sha"] == "bound-sha"

    assert {:error, :invalid_facts} =
             Requests.update(r.id, "pi", "build", %{"expected_sha" => "other"})

    assert {:error, :invalid_facts} =
             Requests.update(r.id, "pi", "build", %{"options" => ["Skip"]})
  end

  test "updates refuse other sessions and terminal cards and still lint options", %{request: r} do
    assert {:error, :forbidden} =
             Requests.update(r.id, "pi", "other", %{"question" => "Changed?"})

    assert {:error, :forbidden} = Requests.update(r.id, "claude", "build", %{})

    assert {:error, %{error: "card_unclear"}} =
             Requests.update(r.id, "pi", "build", %{"options" => ["Tomorrow"]})

    assert {:ok, updated} =
             Requests.update(r.id, "pi", "build", %{
               "options" => ["Tomorrow"],
               "option_details" => %{"Tomorrow" => "Ship tomorrow"}
             })

    assert updated.facts["options"] == ["Tomorrow"]
    assert {:ok, _} = Requests.resolve(r.id, :answer, %{"answer" => "Tomorrow"})

    assert {:error, %{error: "not_pending", state: "answered"}} =
             Requests.update(r.id, "pi", "build", %{})
  end

  test "wrong question requires a reason and returns a distinct terminal outcome", %{request: r} do
    assert {:error, :invalid} = Requests.resolve(r.id, :wrong_question, %{"note" => " "})

    assert {:ok, ended} =
             Requests.resolve(r.id, :wrong_question, %{"note" => "Friday is a holiday"})

    assert ended.state == "wrong_question"
    assert ended.note == "Friday is a holiday"
    assert Foreman.RequestWait.resolved?(nil, %{"state" => ended.state})
    assert {:error, :invalid} = Requests.resolve(r.id, :answer, %{"answer" => "Friday"})
  end

  test "wrong question ends every pending kind without executing work", %{request: r} do
    for kind <- ~w(push open_pr merge review_ui session_waiting chore) do
      {:ok, copy} = Requests.ask({"sample", "s-1"}, "decision", %{"facts" => r.facts})
      copy |> Ecto.Changeset.change(kind: kind) |> Foreman.Repo.update!()

      assert {:ok, ended} =
               Requests.resolve(copy.id, :wrong_question, %{"note" => "The premise is wrong"})

      assert ended.state == "wrong_question"
      assert ended.note == "The premise is wrong"
    end

    assert Foreman.Repo.aggregate(Oban.Job, :count) == 0
  end

  test "updates refuse all non-pending states", %{request: r} do
    for state <-
          ~w(new approved answered declined wrong_question withdrawn superseded executing done failed) do
      r |> Ecto.Changeset.change(state: state) |> Foreman.Repo.update!()

      assert {:error, %{error: "not_pending", state: ^state}} =
               Requests.update(r.id, "pi", "build", %{"question" => "Changed?"})

      assert Requests.get(r.id).facts == r.facts
    end
  end

  test "CLI updates send only supplied fields" do
    assert {:ok, %{request: command}} =
             Foreman.CLI.parse(["ask", "update", Ecto.UUID.generate(), "--text", "New text"])

    assert command["action"] == "ask_update"
    assert command["facts"] == %{"text" => "New text"}
  end

  test "the asking session edits the pending card without replacing its identity", %{request: r} do
    assert {:ok, updated} =
             Requests.update(r.id, "pi", "build", %{
               "question" => "Which delivery date?",
               "text" => "What: Date\nPart of: Release\nWhy now: Schedule"
             })

    assert updated.id == r.id
    assert updated.state == "pending"
    assert updated.facts["question"] == "Which delivery date?"
    assert updated.edited_at
    assert Requests.pending_count() == 1
  end
end
