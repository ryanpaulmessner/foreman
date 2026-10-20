defmodule ForemanWeb.PriorityLiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Foreman.{Priority, Requests}

  setup do
    {:ok, config} =
      Foreman.Config.parse_layers([{"defaults", File.read!("priv/foreman.defaults.toml")}])

    config =
      Map.put(config, "repos", [%{"key" => "sample", "path" => "/tmp/sample", "enabled" => true}])

    Foreman.Repo.insert_all("board_config", [
      %{
        id: 1,
        config: config,
        source: "/tmp/settings",
        discovered: [],
        loaded_at: DateTime.utc_now()
      }
    ])

    :ok
  end

  defp project(rows),
    do:
      {:ok, _} =
        Foreman.Beads.Projection.replace("sample", Enum.map_join(rows, "\n", &Jason.encode!/1))

  defp b(id, type, priority, extra \\ %{}),
    do:
      Map.merge(
        %{id: id, title: "Title #{id}", issue_type: type, status: "open", priority: priority},
        extra
      )

  defp child(id, parent, priority, extra \\ %{}),
    do:
      b(
        id,
        "task",
        priority,
        Map.put(extra, :dependencies, [%{depends_on_id: parent, type: "parent-child"}])
      )

  defp ids(view, selector),
    do:
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("data-bead")

  test "Unplanned sorts by priority, then newest, with missing priority last", %{conn: conn} do
    project([
      b("p2-old", "task", 2, %{created: "2026-01-01"}),
      b("p2-new", "task", 2, %{created: "2026-10-01"}),
      b("none", "task", nil, %{created: "2026-10-20"}),
      b("p0", "task", 0, %{created: "2025-01-01"}),
      b("p1", "task", 1)
    ])

    {:ok, view, _} = live(conn, "/")
    view |> element("#toggle-unplanned") |> render_click()
    view |> element("#toggle-project-sample") |> render_click()

    assert ids(view, "#unplanned [data-bead]") == ~w(p0 p1 p2-new p2-old none)
    assert has_element?(view, "#unplanned [data-bead=p0] [data-priority='0']", "P0")
    assert has_element?(view, "#unplanned [data-bead=p2-old] [data-priority='2']", "P2")
    refute has_element?(view, "#unplanned [data-bead=none] [data-priority]")
  end

  test "epics sort by their own priority and children do not inherit it", %{conn: conn} do
    project([
      b("e1", "epic", 3),
      b("e2", "epic", 0),
      child("e1.1", "e1", 4),
      child("e1.2", "e1", 1),
      child("e1.3", "e1", nil)
    ])

    {:ok, view, _} = live(conn, "/")
    assert ids(view, "#epics > [data-kind=epic]") == ~w(e2 e1)
    assert has_element?(view, "#epics [data-bead=e2] [data-priority='0']")

    view |> element("#epics [data-bead=e1] button") |> render_click()
    assert ids(view, "#epics [data-kind=ticket]") == ~w(e1.2 e1.1 e1.3)
    refute has_element?(view, "#epics [data-bead='e1.3'] [data-priority]")

    {:ok, epic, _} = live(conn, "/epics/sample/e1")
    assert has_element?(epic, "#epic-priority", "P3")
    assert has_element?(epic, "[data-ticket='e1.2'] [data-priority='1']")

    epic |> form("#epic-priority-controls-form", priority: %{value: "0"}) |> render_change()
    assert has_element?(epic, "#epic-priority", "P0")
    assert [%{id: "e1", priority: 0, file_priority: 3}] = Priority.overrides()
  end

  test "the ticket detail changes priority on the board without writing the file", %{conn: conn} do
    project([b("t", "task", 2), b("u", "task", 3)])
    {:ok, view, _} = live(conn, "/?ticket=sample:t")

    assert has_element?(view, "#ticket-priority", "P2")
    refute has_element?(view, "#ticket-priority-changed")

    view |> form("#ticket-priority-controls-form", priority: %{value: "1"}) |> render_change()

    assert has_element?(view, "#ticket-priority[data-priority='1']")
    assert has_element?(view, "#ticket-priority-changed", "Changed on board")
    assert has_element?(view, "#ticket-priority-changed", "file P2")

    view |> element("#toggle-unplanned") |> render_click()
    view |> element("#toggle-project-sample") |> render_click()
    assert ids(view, "#unplanned [data-bead]") == ~w(t u)
    assert has_element?(view, "#unplanned [data-bead=t] [data-priority='1']")

    # The next file sync carrying the same value clears "changed on board".
    project([b("t", "task", 1), b("u", "task", 3)])
    send(view.pid, {:notification, :foreman_events, "sample/t"})
    assert has_element?(view, "#ticket-priority[data-priority='1']")
    refute has_element?(view, "#ticket-priority-changed")
    assert Priority.overrides() == []
  end

  test "Jump to front sets P0, records the board event and leaves queued-only", %{conn: conn} do
    project([b("t", "task", 3), b("d", "task", 2)])
    {:ok, view, _} = live(conn, "/?ticket=sample:t")

    view |> element("#ticket-priority-controls-jump") |> render_click()

    assert has_element?(view, "#ticket-priority[data-priority='0']")
    assert [%{id: "t"}] = Priority.pending_jumps()

    view |> element("#ticket-tabs [phx-click]", "Stage history") |> render_click()
    assert has_element?(view, "#ticket-history", "jump")

    {:ok, _} = Foreman.Overlay.apply_event({"sample", "d"}, {:dispatch, %{window: "w"}})
    {:ok, other, _} = live(conn, "/?ticket=sample:d")
    assert has_element?(other, "#ticket-priority-controls-form")
    refute has_element?(other, "#ticket-priority-controls-jump")
  end

  test "Needs you lists cards by ticket priority, then oldest, with the badge", %{conn: conn} do
    project([b("low", "task", 3), b("high", "task", 0), b("none", "task", nil)])

    ids =
      for id <- ~w(low none high) do
        {:ok, request} =
          Requests.ask({"sample", id}, "decision", %{"facts" => %{"question" => "Go #{id}?"}})

        request.id
      end

    [low, none, high] = ids
    {:ok, view, _} = live(conn, "/needs-you")

    order =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#pending-requests > article")
      |> LazyHTML.attribute("id")

    assert order == Enum.map([high, low, none], &("request-" <> &1))
    assert has_element?(view, "#request-#{high} [data-priority='0']", "P0")
    refute has_element?(view, "#request-#{none} [data-priority]")
  end
end
