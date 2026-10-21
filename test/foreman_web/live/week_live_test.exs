defmodule ForemanWeb.WeekLiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    {:ok, config} =
      Foreman.Config.parse_layers([{"defaults", File.read!("priv/foreman.defaults.toml")}])

    config =
      Map.put(config, "repos", [
        %{"key" => "work", "path" => "/tmp/week-work", "tickets" => "files", "enabled" => true}
      ])

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

  test "kind sections are ordered, empty ones hidden, and ticket details expand", %{conn: conn} do
    today =
      DateTime.utc_now()
      |> DateTime.shift_zone!("America/Chicago")
      |> DateTime.to_date()
      |> Date.to_iso8601()

    rows =
      for {id, kind} <- [{"a", "feature"}, {"b", "break_fix"}, {"c", "internal"}] do
        %{
          id: id,
          title: "Ticket #{id}",
          issue_type: "task",
          status: "open",
          kind: kind,
          notes: "- #{today}: worked",
          dependencies: []
        }
      end

    Foreman.Beads.Projection.replace("work", Enum.map_join(rows, "\n", &Jason.encode!/1))
    {:ok, view, _} = live(conn, "/week")
    assert has_element?(view, "#week-feature + #week-break_fix + #week-internal")
    refute has_element?(view, "#week-mapping")
    assert has_element?(view, "#this-week-link[aria-current=page]")
    refute has_element?(view, "#week-details-work-a")
    view |> element("#week-toggle-work-a") |> render_click()
    assert has_element?(view, "#week-details-work-a")
    assert has_element?(view, "#week-file-work-a[href='/documents/work?path=tickets%2Fa.md']")
    view |> element("#week-toggle-work-a") |> render_click()
    refute has_element?(view, "#week-details-work-a")
  end

  test "empty week has a clear empty state", %{conn: conn} do
    {:ok, view, _} = live(conn, "/week")
    assert has_element?(view, "#week-empty")
  end
end
