defmodule Foreman.WeekTest do
  use Foreman.DataCase, async: false

  test "local snapshot equals independent SQL activity union plus ticket-file dates" do
    now = ~U[2026-10-21 12:00:00Z]

    rows =
      for id <-
            ~w(stage rejected request request_event note closed parked old boundary future inactive),
          do: %{id: id, title: id, issue_type: "task", status: "open", dependencies: []}

    rows =
      Enum.map(rows, fn row ->
        case row.id do
          "note" -> Map.put(row, :notes, "- 2026-10-20 pi: built\n- 2026-10-25 pi: checked")
          "closed" -> Map.put(row, :closed_at, "2026-10-19T00:00:00Z")
          "parked" -> Map.put(row, :parked, "2026-10-25")
          _ -> row
        end
      end)

    Foreman.Beads.Projection.replace("work", Enum.map_join(rows, "\n", &Jason.encode!/1))
    Foreman.Beads.Projection.replace("other", Enum.map_join(rows, "\n", &Jason.encode!/1))

    # Projection bootstraps stages; this fixture supplies its own activity history.
    Foreman.Repo.query!("DELETE FROM stage_events")

    for {id, time, outcome} <- [
          {"stage", now, "accepted"},
          {"rejected", now, "rejected"},
          {"old", ~U[2026-10-18 12:00:00Z], "accepted"},
          {"boundary", ~U[2026-10-19 03:00:00Z], "accepted"},
          {"future", ~U[2026-10-26 05:00:00Z], "accepted"}
        ] do
      Foreman.Repo.insert_all("stage_events", [
        %{
          repo_key: "work",
          bead_id: id,
          machine: "ticket",
          event: "progress",
          source: "claimed",
          actor: "pi",
          to_stage: "building",
          outcome: outcome,
          inserted_at: time
        }
      ])
    end

    for {id, time} <- [{"request", now}, {"request_event", ~U[2026-10-10 12:00:00Z]}] do
      uuid = Ecto.UUID.bingenerate()

      Foreman.Repo.insert_all("approval_requests", [
        %{
          id: uuid,
          repo_key: "work",
          bead_id: id,
          kind: "decision",
          actor: "pi",
          facts: %{},
          state: "pending",
          inserted_at: time,
          updated_at: time
        }
      ])

      Foreman.Repo.insert_all("request_events", [
        %{
          request_id: uuid,
          event: "reply",
          from_state: "pending",
          to_state: "answered",
          payload: %{},
          effects: %{},
          inserted_at: now
        }
      ])
    end

    expected =
      Foreman.Repo.query!("""
        SELECT DISTINCT bead_id FROM (
          SELECT bead_id, inserted_at FROM stage_events WHERE repo_key = 'work'
          UNION ALL SELECT bead_id, inserted_at FROM approval_requests WHERE repo_key = 'work'
          UNION ALL SELECT r.bead_id, e.inserted_at FROM request_events e
            JOIN approval_requests r ON e.request_id = r.id WHERE r.repo_key = 'work'
        ) activity WHERE inserted_at >= '2026-10-19 05:00:00Z' AND inserted_at < '2026-10-26 05:00:00Z'
        ORDER BY bead_id
      """).rows
      |> List.flatten()

    expected = Enum.sort(expected ++ ~w(note closed parked))
    model = Foreman.Week.snapshot(now)
    items = for section <- model.sections, group <- section.groups, item <- group.items, do: item
    assert Enum.sort(Enum.map(items, & &1.id)) == expected
    assert length(items) == 7
    assert Enum.find(items, &(&1.id == "request_event")).plain_stage == "Waiting on you"
    assert [id] = Enum.find(items, &(&1.id == "request")).request_ids
    assert {:ok, _} = Ecto.UUID.cast(id)
  end

  test "out-of-scope ancestors supply kind and epic but never appear in the week" do
    rows = [
      %{
        id: "epic",
        title: "Shared feature",
        issue_type: "epic",
        kind: "feature",
        status: "open",
        dependencies: []
      }
    ]

    Foreman.Beads.Projection.replace("other", Enum.map_join(rows, "\n", &Jason.encode!/1))
    rows = [%{id: "child", title: "Child", issue_type: "task", status: "open", dependencies: []}]
    Foreman.Beads.Projection.replace("work", Enum.map_join(rows, "\n", &Jason.encode!/1))

    Foreman.Repo.insert_all("epic_links", [
      %{repo_key: "work", bead_id: "child", epic_repo_key: "other", epic_bead_id: "epic"}
    ])

    model = Foreman.Week.snapshot()

    assert [
             %{
               kind: "feature",
               groups: [%{epic_title: "Shared feature", items: [%{id: "child"}]}]
             }
           ] = model.sections
  end

  test "board defaults and overrides validate time zones and repo keys" do
    defaults = File.read!("priv/foreman.defaults.toml")
    assert {:ok, config} = Foreman.Config.parse_layers([{"defaults", defaults}])
    assert config["board"]["timezone"] == "America/Chicago"
    assert config["board"]["week_repos"] == ["work"]

    assert {:ok, config} =
             Foreman.Config.parse_layers([
               {"defaults", defaults},
               {"local", "[board]\ntimezone = 'Europe/London'\nweek_repos = ['sample']"}
             ])

    assert config["board"]["timezone"] == "Europe/London"
    assert config["board"]["week_repos"] == ["sample"]

    assert {:error, _} =
             Foreman.Config.parse_layers([
               {"defaults", defaults},
               {"local", "[board]\ntimezone = 'Not/AZone'"}
             ])

    assert {:error, _} =
             Foreman.Config.parse_layers([
               {"defaults", defaults},
               {"local", "[board]\nweek_repos = 'work'"}
             ])
  end
end
