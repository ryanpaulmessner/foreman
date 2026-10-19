defmodule ForemanWeb.SettingsLiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  use Oban.Testing, repo: Foreman.Repo

  test "renders persisted config and requests a worker reload", %{conn: conn} do
    {:ok, config} =
      Foreman.Config.parse_layers([{"defaults", File.read!("priv/foreman.defaults.toml")}])

    config =
      Map.put(config, "repos", [%{"key" => "sample", "path" => "/tmp/sample", "enabled" => true}])

    Foreman.Repo.insert_all("board_config", [
      %{
        id: 1,
        config: config,
        source: "/tmp/settings",
        discovered: ["/tmp/unconfigured"],
        loaded_at: DateTime.utc_now()
      }
    ])

    Foreman.RuntimeState.record(
      "sample",
      {:warning, ["tickets/demo-abc.md: malformed frontmatter"]}
    )

    {:ok, view, _} = live(conn, "/settings")
    assert has_element?(view, "#repo-sample", "tickets/demo-abc.md: malformed frontmatter")
    assert has_element?(view, "#repo-sample [data-health=warning]", "1 file error")
    refute has_element?(view, "#sidebar-project-sample", "down")
    Foreman.RuntimeState.record("sample", {:error, "tickets: directory unavailable"})
    send(view.pid, :reconcile)
    assert has_element?(view, "#repo-sample [data-health=unreachable]", "unreachable")
    assert has_element?(view, "#repo-sample", "tickets: directory unavailable")
    assert has_element?(view, "#sidebar-project-sample", "down")
    assert has_element?(view, "a.bb-nav-active[aria-current=page]", "Settings")
    refute has_element?(view, "p", "The board never writes")
    assert has_element?(view, "#repo-sample")
    assert has_element?(view, "#discovered-repos pre", "[[repos]]")
    assert has_element?(view, "#enabled-sample[disabled]")
    view |> element("#reload-config") |> render_click()
    assert_enqueued(worker: Foreman.Config.ReloadJob)
    Foreman.Repo.query!("UPDATE board_config SET error = 'bad TOML' WHERE id = 1")
    send(view.pid, :reconcile)
    assert has_element?(view, "#config-error", "last good config")
    assert has_element?(view, "#repo-sample")
  end

  test "a human-merge config error shows in Settings over the last good config", %{conn: conn} do
    {:ok, config} =
      Foreman.Config.parse_layers([{"defaults", File.read!("priv/foreman.defaults.toml")}])

    config =
      Map.put(config, "repos", [%{"key" => "work", "path" => "/tmp/work", "enabled" => true}])

    {:error, error} =
      Foreman.Config.parse_layers([
        {"defaults", File.read!("priv/foreman.defaults.toml")},
        {"foreman.toml",
         "[[repos]]\nkey = \"work\"\npath = \"/tmp/work\"\nmerge_policy = \"human\"\n"}
      ])

    Foreman.Repo.insert_all("board_config", [
      %{
        id: 1,
        config: config,
        error: error,
        source: "/tmp/settings",
        discovered: [],
        loaded_at: DateTime.utc_now()
      }
    ])

    {:ok, view, _} = live(conn, "/settings")
    assert has_element?(view, "#config-error", "requires forge = \"github\"")
    assert has_element?(view, "#config-error", "last good config")
    assert has_element?(view, "#repo-work")
  end
end
