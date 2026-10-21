defmodule Foreman.AnswersTest do
  use Foreman.DataCase, async: false
  alias Foreman.Answers

  test "a new version keeps the previous content and metadata" do
    {:ok, answer} =
      Answers.create(%{
        "question" => "Why?",
        "body" => "Old",
        "actor" => "pi",
        "repo" => "sample",
        "links" => ["docs/spec.md"]
      })

    assert {:ok, updated} = Answers.update(answer.id, %{"body" => "New", "actor" => "ryan"})
    assert [latest, earlier] = updated.versions
    assert latest.body == "New"
    assert latest.question == "Why?"
    assert latest.repo == "sample"
    assert latest.links == ["docs/spec.md"]
    assert earlier.body == "Old"
    assert earlier.actor == "pi"
    assert latest.actor == "ryan"
  end

  test "lists pinned first, searches latest text, filters, and hides archives" do
    {:ok, first} =
      Answers.create(%{
        "question" => "First",
        "body" => "needle",
        "actor" => "pi",
        "repo" => "sample",
        "ticket" => "fm-1"
      })

    {:ok, second} = Answers.create(%{"question" => "Second", "body" => "Other", "actor" => "pi"})
    assert Enum.map(Answers.list(), & &1.id) == [second.id, first.id]
    assert {:ok, _} = Answers.change_state(first.id, :pin)
    assert Enum.map(Answers.list(), & &1.id) == [first.id, second.id]
    assert [found] = Answers.list(%{"search" => "NEEDLE", "repo" => "sample", "ticket" => "fm-1"})
    assert found.id == first.id
    assert Answers.list(%{"ticket" => "fm-2"}) == []
    assert {:ok, _} = Answers.change_state(first.id, :archive)
    assert Enum.map(Answers.list(), & &1.id) == [second.id]
    assert length(Answers.list(%{"archived" => "true"})) == 2
    assert {:ok, _} = Answers.change_state(first.id, :restore)
    assert Answers.get(first.id).state == :pinned
    assert {:ok, _} = Answers.change_state(first.id, :unpin)
    assert Answers.get(first.id).state == :normal
  end

  test "rejects blank content without leaving an answer" do
    assert {:error, _} = Answers.create(%{"question" => "  ", "body" => "", "actor" => "pi"})
    assert Answers.list() == []
    assert {:error, :not_found} = Answers.update("not-an-id", %{})
  end

  test "keeps a question and Markdown with its author" do
    assert {:ok, answer} =
             Answers.create(%{
               "question" => "Why?",
               "body" => "**Because**",
               "actor" => "pi",
               "session" => "build"
             })

    assert answer.state == :normal
    assert [version] = answer.versions
    assert version.question == "Why?"
    assert version.body == "**Because**"
    assert version.actor == "pi"
    assert version.session == "build"
  end
end
