defmodule ForemanWeb.EpicCoordinatorControlsTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Foreman.{AgentSessions, Repo}

  setup do
    {:ok, config} =
      Foreman.Config.parse_layers([{"defaults", File.read!("priv/foreman.defaults.toml")}])

    Repo.insert_all("board_config", [
      %{
        id: 1,
        config:
          Map.put(config, "repos", [
            %{"key" => "sample", "path" => "/tmp/sample", "enabled" => true}
          ]),
        source: "test",
        discovered: [],
        loaded_at: DateTime.utc_now()
      }
    ])

    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "lc", title: "Coordinator epic", issue_type: "epic", status: "open"})
    )

    :ok
  end

  for {state, label, busy} <- [
        {nil, "Launch coordinator", "Launching…"},
        {:running, "Focus", "Focusing…"},
        {:parked, "Resume", "Resuming…"},
        {:ended, "Resume", "Resuming…"}
      ] do
    test "both screens show #{label} for #{inspect(state)}", %{conn: conn} do
      row = planning(unquote(state))

      for {path, selector} <- [
            {"/", "button[id^='launch-']"},
            {"/epics/sample/lc", "#epic-launch"}
          ] do
        {:ok, view, _} = live(conn, path)

        assert has_element?(
                 view,
                 "#{selector}[phx-disable-with='#{unquote(busy)}']",
                 unquote(label)
               )

        if row, do: assert(has_element?(view, "a[href='/sessions/#{row.id}']", "lc"))
      end
    end
  end

  for stage <- ["done", "abandoned"] do
    test "#{stage} has no control even with an ended session", %{conn: conn} do
      planning(:ended)
      Repo.update_all("epics", set: [stage: unquote(stage)])

      for {path, selector} <- [
            {"/", "button[id^='launch-']"},
            {"/epics/sample/lc", "#epic-launch"}
          ] do
        {:ok, view, _} = live(conn, path)
        refute has_element?(view, selector)
      end
    end
  end

  test "a registered live coordinator offers Focus on both screens", %{conn: conn} do
    {:ok, row} =
      AgentSessions.create(%{
        name: "lc",
        kind: "epic_coordinator",
        harness: "claude",
        tmux_server: "default",
        pane_id: "%99"
      })

    for path <- ["/", "/epics/sample/lc"] do
      {:ok, view, _} = live(conn, path)
      assert has_element?(view, "button[phx-value-action='focus']", "Focus")
      assert has_element?(view, "a[href='/sessions/#{row.id}']")
    end
  end

  test "an ended registration without a planning resume path keeps only its link", %{conn: conn} do
    {:ok, row} =
      AgentSessions.create(%{
        name: "lc",
        kind: "epic_coordinator",
        harness: "claude",
        tmux_server: "default"
      })

    AgentSessions.end_session(row)

    for path <- ["/", "/epics/sample/lc"] do
      {:ok, view, _} = live(conn, path)
      refute has_element?(view, "button[phx-click='launch-session']")
      assert has_element?(view, "a[href='/sessions/#{row.id}']")
    end
  end

  test "a failed launch without a window can be retried", %{conn: conn} do
    row =
      Repo.insert!(%Foreman.PlanningSession{
        project: "sample",
        ticket: "lc",
        state: :starting,
        workdir: "/tmp/sample",
        error: "Launch failed; check tmux and retry",
        launched_at: DateTime.utc_now()
      })

    Repo.transaction(fn -> AgentSessions.sync_planning(row) end)

    for path <- ["/", "/epics/sample/lc"] do
      {:ok, view, _} = live(conn, path)
      assert has_element?(view, "button[phx-value-action='launch']", "Launch coordinator")
      refute has_element?(view, "button[phx-value-action='focus']")
    end
  end

  defp planning(nil), do: nil

  defp planning(state) do
    row =
      Repo.insert!(%Foreman.PlanningSession{
        project: "sample",
        ticket: "lc",
        state: state,
        window: "@999",
        workdir: "/tmp/sample",
        launched_at: DateTime.utc_now()
      })

    {:ok, identity} = Repo.transaction(fn -> AgentSessions.sync_planning(row) end)
    identity
  end
end
