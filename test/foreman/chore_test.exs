defmodule Foreman.ChoreTest do
  use Foreman.DataCase, async: false
  alias Foreman.{Requests, Overlay, Repo}

  setup do
    Overlay.backfill("sample", [
      %{bead_id: "s-1", status: "open", issue_type: "task"},
      %{bead_id: "s-2", status: "open", issue_type: "task"}
    ])

    :ok
  end

  defp ask(ticket, key \\ "signin:preview.example") do
    Requests.ask({"sample", ticket}, "chore", %{
      "actor" => "pi",
      "session" => ticket,
      "facts" => %{
        "question" => "Sign in to previews",
        "steps" => ["Open a preview", "Sign in"],
        "key" => key
      }
    })
  end

  test "asks with the same key join the pending chore across tickets, but not a completed chore" do
    {:ok, first} = ask("s-1")
    assert {:ok, joined} = ask("s-2")
    assert joined.id == first.id
    assert Requests.pending_count() == 1
    {:ok, _} = Requests.resolve(first.id, :complete, %{})
    assert Requests.get(joined.id).state == "done"
    assert {:ok, next} = ask("s-2")
    refute next.id == first.id
    assert {:ok, separate} = ask("s-1", nil)
    refute separate.id == next.id
  end

  test "a sign-in key joins one pending chore across repositories" do
    Overlay.backfill("other", [%{bead_id: "o-1", status: "open", issue_type: "task"}])
    {:ok, first} = ask("s-1")

    assert {:ok, joined} =
             Requests.ask({"other", "o-1"}, "chore", %{
               "facts" => %{
                 "question" => "Sign in",
                 "steps" => ["Sign in"],
                 "key" => "signin:preview.example"
               }
             })

    assert joined.id == first.id
    assert Requests.pending_count() == 1
  end

  test "CLI collects steps and a shared key" do
    assert {:ok, %{request: r}} =
             Foreman.CLI.parse([
               "ask",
               "chore",
               "s-1",
               "--question",
               "Sign in",
               "--step",
               "Open preview",
               "--step",
               "Sign in",
               "--key",
               "signin:host"
             ])

    assert r["request_kind"] == "chore"
    assert r["facts"]["steps"] == ["Open preview", "Sign in"]
    assert r["facts"]["key"] == "signin:host"
  end

  test "a chore records steps and completes without an approval job" do
    assert {:ok, request} = ask("s-1")
    assert request.facts["steps"] == ["Open a preview", "Sign in"]
    assert {:error, :invalid} = Requests.resolve(request.id, :approve, %{})
    assert {:error, :invalid} = Requests.resolve(request.id, :answer, %{"answer" => "Done"})
    assert {:ok, done} = Requests.resolve(request.id, :complete, %{})
    assert done.state == "done"
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert {:error, :invalid} = Requests.resolve(request.id, :complete, %{})
  end
end
