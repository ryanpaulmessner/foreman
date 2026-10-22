defmodule Foreman.OverlayTest do
  use Foreman.DataCase, async: false
  alias Foreman.{Overlay, Repo}

  test "backfill records closed and open tickets but gives epics only an epic stage" do
    :ok =
      Overlay.backfill("sample", [
        bead("a", "closed"),
        bead("b", "open"),
        bead("e", "open", "epic")
      ])

    assert %{stage: :done} = Overlay.get({"sample", "a"})
    assert %{stage: :queued} = Overlay.get({"sample", "b"})
    assert %{stage: :ticketed} = Overlay.get({"sample", "e"})
    assert Repo.aggregate(from(t in "tickets", where: t.bead_id == "e"), :count) == 0
    assert [%{source: "backfill", to_stage: "done"}] = Overlay.history({"sample", "a"})
    :ok = Overlay.backfill("sample", [bead("a", "closed")])
    assert length(Overlay.history({"sample", "a"})) == 1
  end

  test "claims step the machine, persist effects, and log invalid claims without changing state" do
    Overlay.backfill("sample", [bead("b", "open")])
    key = {"sample", "b"}
    assert {:error, %{stage: :queued, allowed: allowed}} = Overlay.apply_event(key, :review)
    assert :dispatch in allowed
    assert List.last(Overlay.history(key)).outcome == "invalid"

    assert {:ok, %{stage: :dispatched}} =
             Overlay.apply_event(key, {:dispatch, %{window: "build", branch: "feature"}}, %{
               actor: "pi"
             })

    assert Repo.one(from s in "sessions", select: s.window) == "build"
    assert {:ok, %{stage: :building}} = Overlay.apply_event(key, {:progress, %{body: "Working"}})

    assert Repo.one(from n in "agent_notes", where: n.kind == "progress", select: n.body) ==
             "Working"

    assert {:error, %{stage: :building}} =
             Overlay.apply_event(key, {:dispatch, %{window: "build"}})

    assert {:ok, %{stage: :dispatched}} =
             Overlay.apply_event(key, {:dispatch, %{window: "second"}})
  end

  test "spec approval records an optional design link" do
    key = {"sample", "draft:design"}
    assert {:ok, _} = Overlay.apply_event(key, {:create, %{title: "Design"}})
    assert {:ok, _} = Overlay.apply_event(key, :start_spec)

    assert {:ok, _} =
             Overlay.apply_event(
               key,
               {:approve_spec, %{spec_link: "docs/spec.md", design_link: "docs/design.md"}}
             )

    assert Map.get(Overlay.get(key), :design_link) == "docs/design.md"
    assert Overlay.document_reference?("sample", "docs/design.md")
  end

  test "draft creation and ticket linkage preserve one epic identity and its history" do
    key = {"sample", "draft:new-board"}

    assert {:ok, %{stage: :idea}} =
             Overlay.apply_event(key, {:create, %{title: "New board", spec_link: "docs/spec.md"}})

    assert {:ok, %{stage: :speccing}} = Overlay.apply_event(key, :start_spec)

    assert {:ok, %{stage: :spec_approved}} =
             Overlay.apply_event(key, {:approve_spec, %{spec_link: "docs/approved.md"}})

    assert {:ok, %{stage: :ticketed}} = Overlay.apply_event(key, {:ticket, %{beads_epic_id: "e"}})
    Overlay.backfill("sample", [bead("e", "open", "epic")])

    assert %{bead_id: "draft:new-board", spec_link: "docs/approved.md", stage: :ticketed} =
             Overlay.get({"sample", "e"})

    assert length(Overlay.history({"sample", "e"})) == 4
  end

  test "linking an already observed closed epic preserves append-only history and closure" do
    Overlay.backfill("sample", [bead("e", "closed", "epic")])

    original =
      Repo.one(
        from e in "stage_events", where: e.bead_id == "e", select: %{id: e.id, bead_id: e.bead_id}
      )

    key = {"sample", "draft:linked"}
    Overlay.apply_event(key, {:create, %{title: "Linked"}})
    Overlay.apply_event(key, :start_spec)
    Overlay.apply_event(key, :approve_spec)
    assert {:ok, %{stage: :done}} = Overlay.apply_event(key, {:ticket, %{beads_epic_id: "e"}})

    assert Repo.one(from e in "stage_events", where: e.id == ^original.id, select: e.bead_id) ==
             "e"

    assert Enum.any?(Overlay.history(key), &(&1.id == original.id))
    assert %{stage: :done} = Overlay.get({"sample", "e"})
  end

  test "an explicit epic self-transition is recorded as a row, not ignored" do
    Overlay.backfill("sample", [bead("e", "closed", "epic")])
    Overlay.apply_event({"sample", "e"}, :bead_epic_closed)
    assert List.last(Overlay.history({"sample", "e"})).outcome == "row"
  end

  test "failure rolls back stage, event and all effects together" do
    Overlay.backfill("sample", [bead("b", "open")])
    assert {:error, :window_required} = Overlay.apply_event({"sample", "b"}, :dispatch)
    assert %{stage: :queued, lock_version: 1} = Overlay.get({"sample", "b"})
    assert length(Overlay.history({"sample", "b"})) == 1
    assert Repo.aggregate("sessions", :count) == 0
  end

  test "open CR guard uses persisted links and observed facts never become invalid" do
    key = {"sample", "b"}
    Overlay.backfill("sample", [bead("b", "open")])
    assert {:ok, %{stage: :pr_open}} = Overlay.apply_event(key, {:cr_opened, %{number: 1}})
    Overlay.apply_event(key, {:cr_opened, %{number: 2}})
    assert {:ok, %{stage: :pr_open}} = Overlay.apply_event(key, {:cr_closed, %{number: 1}})
    assert {:ok, %{stage: :committed}} = Overlay.apply_event(key, {:cr_closed, %{number: 2}})
    assert {:ok, %{stage: :committed}} = Overlay.apply_event(key, :bead_reopened)
    assert List.last(Overlay.history(key)).outcome == "ignored"
  end

  test "projection sync observes closure and reopening while rebuilds preserve workflow history" do
    raw = %{"id" => "b", "title" => "Ticket", "issue_type" => "task", "status" => "open"}
    Foreman.Beads.Projection.replace("sample", Jason.encode!(raw))
    assert %{stage: :queued} = Overlay.get({"sample", "b"})
    Overlay.apply_event({"sample", "b"}, {:dispatch, %{window: "build"}})
    Foreman.Beads.Projection.replace("sample", Jason.encode!(%{raw | "status" => "closed"}))
    assert %{stage: :done} = Overlay.get({"sample", "b"})
    Foreman.Beads.Projection.replace("sample", Jason.encode!(raw))
    assert %{stage: :queued} = Overlay.get({"sample", "b"})
    Overlay.apply_event({"sample", "b"}, {:dispatch, %{window: "again"}})
    Repo.delete_all("bead_repos")
    Foreman.Beads.Projection.replace("sample", Jason.encode!(raw))
    assert %{stage: :dispatched} = Overlay.get({"sample", "b"})
    assert length(Overlay.history({"sample", "b"})) == 5
  end

  defp bead(id, status, type \\ "task"), do: %{bead_id: id, status: status, issue_type: type}
end
