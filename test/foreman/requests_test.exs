defmodule Foreman.RequestsTest do
  use Foreman.DataCase, async: false
  alias Foreman.{Requests, Overlay, Repo}

  setup do
    Overlay.backfill("sample", [%{bead_id: "s-1", status: "open", issue_type: "task"}])
    :ok
  end

  defp ask do
    Requests.ask({"sample", "s-1"}, "decision", %{
      "actor" => "pi",
      "session" => "build",
      "facts" => %{
        "question" => "Which layout?",
        "options" => ["Wide", "Compact"],
        "recommendation" => "Compact"
      }
    })
  end

  test "a decision stores immutable facts and asker, then returns the answer" do
    assert {:ok, request} = ask()
    assert request.state == "pending"
    assert request.actor == "pi"
    assert request.session == "build"
    assert {:ok, answered} = Requests.resolve(request.id, :answer, %{"answer" => "Compact"})
    assert answered.state == "answered"
    assert answered.outcome == %{"answer" => "Compact"}
    assert answered.facts == request.facts
    assert {:error, :invalid} = Requests.resolve(request.id, :decline, %{})
  end

  test "only the asker can withdraw a pending request, with a reason" do
    {:ok, request} = ask()
    assert {:error, :forbidden} = Requests.withdraw(request.id, "other", "build", "Answered")
    assert {:error, :forbidden} = Requests.withdraw(request.id, "pi", "other", "Answered")
    assert {:error, :invalid} = Requests.withdraw(request.id, "pi", "build", " ")
    assert {:ok, result} = Requests.withdraw(request.id, "pi", "build", "Answered in chat")
    assert result.state == "withdrawn"
    assert result.outcome == %{"reason" => "Answered in chat"}
    refute Enum.any?(Requests.pending(), &(&1.id == request.id))
    assert {:error, :invalid} = Requests.withdraw(request.id, "pi", "build", "Again")
  end

  test "withdraw refuses every non-pending state" do
    for state <- ~w(new approved answered declined withdrawn superseded executing done failed) do
      {:ok, request} = ask()
      request |> Ecto.Changeset.change(state: state) |> Repo.update!()
      assert {:error, :invalid} = Requests.withdraw(request.id, "pi", "build", "Stale")
      assert Requests.get(request.id).state == state
    end
  end

  test "unknown options and blank consequence text are refused" do
    for details <- [%{"Other" => "Do something"}, %{"A" => " "}, ["bad"]] do
      assert {:error, :invalid_facts} =
               Requests.ask({"sample", "s-1"}, "decision", %{
                 "facts" => %{
                   "question" => "Which?",
                   "options" => ["A"],
                   "option_details" => details
                 }
               })
    end
  end

  test "decline records note and enqueues nothing" do
    {:ok, request} = ask()
    assert {:ok, result} = Requests.resolve(request.id, :decline, %{"note" => "Not this slice"})
    assert result.state == "declined"
    assert result.note == "Not this slice"
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "a decision's --doc paths are stored as {repo, path}; outside paths are refused" do
    root = Foreman.ScratchDocs.dir("requests-docs")
    Foreman.ScratchDocs.write(root, %{"reports/27.md" => "# Report"})
    outside = Foreman.ScratchDocs.write(Foreman.ScratchDocs.dir("outside"), %{"x.md" => "# X"})
    on_exit(fn -> File.rm_rf!(root) && File.rm_rf!(outside) end)
    Foreman.ScratchDocs.configure(%{"sample" => root})

    facts = fn docs -> %{"facts" => %{"question" => "Ship?", "docs" => docs}} end

    assert {:ok, request} =
             Requests.ask(
               {"sample", "s-1"},
               "decision",
               facts.(["reports/27.md", root <> "/reports/27.md"])
             )

    assert request.facts["docs"] == [%{"repo" => "sample", "path" => "reports/27.md"}]

    for docs <- [[outside <> "/x.md"], ["reports/missing.md"], ["../x.md"], "reports/27.md"] do
      assert {:error, :invalid_doc} = Requests.ask({"sample", "s-1"}, "decision", facts.(docs))
    end

    assert {:ok, plain} = Requests.ask({"sample", "s-1"}, "decision", facts.([]))
    refute Map.has_key?(plain.facts, "docs")
    assert Requests.pending_count() == 2
  end

  test "draft request headers use the board title" do
    Foreman.Overlay.apply_event({"sample", "draft:plan"}, {:create, %{title: "Mobile access"}})

    {:ok, request} =
      Requests.ask({"sample", "draft:plan"}, "decision", %{"facts" => %{"question" => "Build?"}})

    assert Foreman.RequestHeader.for_request(request).title == "Mobile access"
  end

  test "bad kinds and facts are refused before recording" do
    for {kind, facts} <- [
          {"push", %{}},
          {"decision", %{}},
          {"decision", %{"question" => "?", "options" => [1]}}
        ] do
      assert {:error, _} = Requests.ask({"sample", "s-1"}, kind, %{"facts" => facts})
    end

    assert Requests.pending_count() == 0
  end

  test "ticketed draft keeps requests posted to either epic identity" do
    Overlay.backfill("sample", [%{bead_id: "s-e", status: "open", issue_type: "epic"}])

    {:ok, original} =
      Requests.ask({"sample", "s-e"}, "decision", %{"facts" => %{"question" => "Original?"}})

    key = {"sample", "draft:plan"}
    Overlay.apply_event(key, {:create, %{title: "Plan"}})
    {:ok, draft} = Requests.ask(key, "decision", %{"facts" => %{"question" => "Draft?"}})
    Overlay.apply_event(key, :start_spec)
    Overlay.apply_event(key, :approve_spec)
    Overlay.apply_event(key, {:ticket, %{beads_epic_id: "s-e"}})
    assert MapSet.new(Requests.for_ticket(key), & &1.id) == MapSet.new([original.id, draft.id])
    assert {:ok, _} = Overlay.apply_event(key, :bead_epic_closed)
    assert Requests.get(original.id).state == "pending"
    assert Requests.get(draft.id).state == "pending"
  end

  test "blank answer is rejected without changing the request" do
    {:ok, request} = ask()
    assert {:error, :invalid} = Requests.resolve(request.id, :answer, %{"answer" => "   "})
    assert Requests.get(request.id).state == "pending"
    assert Repo.aggregate("request_events", :count) == 1
  end

  for event <- [:abandon, :bead_closed] do
    test "#{event} supersedes action requests but keeps decisions and other kinds" do
      actions =
        for kind <- ~w(push open_pr merge) do
          {:ok, request} = ask()
          request |> Ecto.Changeset.change(kind: kind) |> Repo.update!()
        end

      {:ok, other} = ask()
      other |> Ecto.Changeset.change(kind: "session_waiting") |> Repo.update!()
      {:ok, pending} = ask()
      {:ok, answered} = ask()
      Requests.resolve(answered.id, :answer, %{"answer" => "Other"})
      Overlay.apply_event({"sample", "s-1"}, unquote(event))
      for request <- actions, do: assert(Requests.get(request.id).state == "superseded")
      assert Requests.get(other.id).state == "pending"
      assert Requests.get(pending.id).state == "pending"
      assert Requests.get(answered.id).state == "answered"
      assert {:error, :ticket_finished} = ask()
    end
  end
end
