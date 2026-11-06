defmodule ForemanWeb.SessionsGridLiveTest do
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Foreman.AgentSessionFixtures

  setup do
    capture_runner = Application.fetch_env!(:foreman, :pane_capture_runner)
    Application.put_env(:foreman, :session_tree_tmux, runner: fn _, _, _ -> {"", 0} end)

    on_exit(fn ->
      Application.delete_env(:foreman, :session_tree_tmux)
      Application.put_env(:foreman, :pane_capture_runner, capture_runner)
    end)
  end

  test "visible output is pushed only on change and hidden tabs stop reads", %{conn: conn} do
    row = agent_session(pane_id: "%1")
    owner = self()
    clock = start_supervised!({Agent, fn -> 0 end})
    Application.put_env(:foreman, :grid_clock, fn -> Agent.get(clock, & &1) end)
    on_exit(fn -> Application.delete_env(:foreman, :grid_clock) end)

    Application.put_env(:foreman, :pane_capture_runner, fn _, args, _ ->
      send(owner, :captured)
      markers = Enum.filter(args, &String.starts_with?(&1, "foreman-"))

      text =
        Enum.map_join(markers, "\n", fn marker ->
          if String.ends_with?(marker, ":start"),
            do: marker <> "\nhello\n" <> String.replace_suffix(marker, ":start", ":ok"),
            else: marker
        end)

      {text <> "\n", 0}
    end)

    {:ok, view, _} = live(conn, "/sessions")
    render_hook(view, "restore-sessions-view", %{"view" => "grid"})
    render_hook(view, "grid_visibility", %{"ids" => [row.id, "unknown"], "visible" => true})
    send(view.pid, :check_connection)
    assert has_element?(view, "#grid-card-#{row.id}")
    render_async(view)
    assert_receive :captured
    assert_push_event(view, "grid_output", %{id: id, html: "hello", empty: false})
    assert id == row.id
    send(view.pid, :check_connection)
    render(view)
    refute_receive :captured
    refute_push_event(view, "grid_output", _)
    Agent.update(clock, fn _ -> 3000 end)
    send(view.pid, :check_connection)
    render(view)
    render_async(view)
    assert_receive :captured
    refute_push_event(view, "grid_output", _)
    Agent.update(clock, fn _ -> 6000 end)
    render_hook(view, "grid_visibility", %{"ids" => [row.id], "visible" => false})
    send(view.pid, :check_connection)
    render(view)
    refute_receive :captured
  end

  test "Tree is default; switch saves and restores the viewer preference", %{conn: conn} do
    row = agent_session()
    {:ok, view, _} = live(conn, "/sessions")
    assert has_element?(view, "#sessions-view-tree[aria-pressed=true]")
    view |> element("#sessions-view-grid") |> render_click()
    assert_push_event(view, "save-sessions-view", %{view: "grid"})
    assert has_element?(view, "#grid-card-#{row.id}")
    render_hook(view, "restore-sessions-view", %{"view" => "tree"})
    assert has_element?(view, "#sessions-view-tree[aria-pressed=true]")
    render_hook(view, "restore-sessions-view", %{"view" => "invalid"})
    assert has_element?(view, "#sessions-view-tree[aria-pressed=true]")
  end

  test "loading contains three grid groups and connection-loss recovery", %{conn: conn} do
    document = conn |> get("/sessions") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.query(document, "#sessions-grid-loading[hidden] #grid-skeleton-3")
           |> Enum.count() == 1

    assert LazyHTML.query(document, "#sessions-disconnected a") |> LazyHTML.text() ==
             "Reload page"
  end

  test "grid empty states use the same controls", %{conn: conn} do
    {:ok, view, _} = live(conn, "/sessions")
    render_hook(view, "restore-sessions-view", %{"view" => "grid"})
    assert has_element?(view, "#sessions-empty", "No sessions are running")
    view |> element("#show-ended-form") |> render_change(%{})
    assert has_element?(view, "#sessions-empty", "No sessions ended in the last 7 days.")
  end

  test "dead cards have no capture and a closed-terminal chip", %{conn: conn} do
    row = agent_session() |> Foreman.AgentSessions.end_session()
    {:ok, view, _} = live(conn, "/sessions")
    render_hook(view, "restore-sessions-view", %{"view" => "grid"})
    view |> element("#show-ended-form") |> render_change(%{})
    assert has_element?(view, "#grid-card-#{row.id}.bb-grid-ended", "The terminal is closed")
    refute has_element?(view, "#grid-card-#{row.id}[data-grid-live]")
  end

  test "an in-flight result from a previous tmux server is not pushed", %{conn: conn} do
    row = agent_session(pane_id: "%1")
    owner = self()

    Application.put_env(:foreman, :pane_capture_runner, fn _, args, _ ->
      send(owner, {:reader_started, self()})

      receive do
        :release -> :ok
      end

      output =
        args
        |> Enum.filter(&String.starts_with?(&1, "foreman-"))
        |> Enum.map_join("\n", fn marker ->
          if String.ends_with?(marker, ":start"),
            do: marker <> "\nstale\n" <> String.replace_suffix(marker, ":start", ":ok"),
            else: marker
        end)

      {output <> "\n", 0}
    end)

    {:ok, view, _} = live(conn, "/sessions")
    render_hook(view, "restore-sessions-view", %{"view" => "grid"})
    render_hook(view, "grid_visibility", %{"ids" => [row.id], "visible" => true})
    send(view.pid, :check_connection)
    assert_receive {:reader_started, pid}
    Foreman.Repo.update!(Ecto.Changeset.change(row, tmux_server: "board"))
    send(view.pid, {:notification, :foreman_events, "{}"})
    render(view)
    send(pid, :release)
    render_async(view)
    refute_push_event(view, "grid_output", _)
  end

  test "hiding cancels an in-flight read without blocking the page", %{conn: conn} do
    row = agent_session(pane_id: "%1")
    owner = self()

    Application.put_env(:foreman, :pane_capture_runner, fn _, _, _ ->
      send(owner, {:reader_started, self()})

      receive do
        :release -> {"", 1}
      end
    end)

    {:ok, view, _} = live(conn, "/sessions")
    render_hook(view, "restore-sessions-view", %{"view" => "grid"})
    render_hook(view, "grid_visibility", %{"ids" => [row.id], "visible" => true})
    send(view.pid, :check_connection)
    assert_receive {:reader_started, pid}
    ref = Process.monitor(pid)
    render_hook(view, "grid_visibility", %{"ids" => [row.id], "visible" => false})
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert has_element?(view, "#grid-card-#{row.id}")
    refute has_element?(view, "#sessions-tmux-error")
  end

  test "retry makes an idle pane due at the next rate-limited check", %{conn: conn} do
    row = agent_session(pane_id: "%1")
    Foreman.Repo.update!(Ecto.Changeset.change(row, state: "idle"))
    clock = start_supervised!({Agent, fn -> 0 end})
    Application.put_env(:foreman, :grid_clock, fn -> Agent.get(clock, & &1) end)
    Application.put_env(:foreman, :pane_capture_runner, fn _, _, _ -> {"down", 1} end)

    on_exit(fn ->
      Application.delete_env(:foreman, :grid_clock)
    end)

    {:ok, view, _} = live(conn, "/sessions")
    render_hook(view, "restore-sessions-view", %{"view" => "grid"})
    render_hook(view, "grid_visibility", %{"ids" => [row.id], "visible" => true})
    send(view.pid, :check_connection)
    render(view)
    render_async(view)
    assert has_element?(view, "#sessions-tmux-error")

    Application.put_env(:foreman, :pane_capture_runner, fn _, args, _ ->
      output =
        args
        |> Enum.filter(&String.starts_with?(&1, "foreman-"))
        |> Enum.map_join("\n", fn marker ->
          if String.ends_with?(marker, ":start"),
            do: marker <> "\nready\n" <> String.replace_suffix(marker, ":start", ":ok"),
            else: marker
        end)

      {output <> "\n", 0}
    end)

    Agent.update(clock, fn _ -> 3000 end)
    view |> element("#sessions-retry") |> render_click()
    send(view.pid, :check_connection)
    render(view)
    render_async(view)
    refute has_element?(view, "#sessions-tmux-error")
    assert_push_event(view, "grid_output", %{html: "ready"})
  end

  test "a dead coordinator stays with its running builds", %{conn: conn} do
    parent = agent_session(kind: "epic_coordinator", name: "parent")
    child = agent_session(parent_id: parent.id)
    Foreman.AgentSessions.end_session(parent)
    {:ok, view, _} = live(conn, "/sessions")
    render_hook(view, "restore-sessions-view", %{"view" => "grid"})
    assert has_element?(view, "#grid-card-#{parent.id}", "Its builds still run")
    assert has_element?(view, "#grid-state-#{child.id}", "Parent ended")
  end

  test "tmux failure fades output and disables focus", %{conn: conn} do
    row = agent_session()
    Application.put_env(:foreman, :session_tree_tmux, runner: fn _, _, _ -> {"", 1} end)
    {:ok, view, _} = live(conn, "/sessions")
    render_hook(view, "restore-sessions-view", %{"view" => "grid"})
    assert has_element?(view, "#sessions-tmux-error")
    assert has_element?(view, "#session-grid.bb-grid-stale")
    assert has_element?(view, "#grid-focus-#{row.id}[disabled]")
  end
end
