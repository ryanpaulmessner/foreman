defmodule ForemanWeb.SessionOutputLiveTest do
  @moduledoc "Recent output on the session page (spec Decisions 14-15, copy table output states)."
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Foreman.AgentSessionFixtures
  alias Foreman.SessionCaptures

  @screen "\e[1mbash\e[0m mix test\n\e[31mred\e[0m and \e]8;;https://hexdocs.pm/x\e\\docs\e]8;;\e\\\n"

  setup do
    default = Application.get_env(:foreman, :pane_capture_runner)
    on_exit(fn -> Application.put_env(:foreman, :pane_capture_runner, default) end)
    :ok
  end

  # Every tmux call the page makes goes to the test process; `reply` answers it.
  defp tmux(reply) do
    parent = self()

    Application.put_env(:foreman, :pane_capture_runner, fn "tmux", args, _ ->
      send(parent, {:tmux, args})
      reply.(args)
    end)
  end

  defp screens(list) do
    {:ok, agent} = Agent.start_link(fn -> list end)

    tmux(fn _ ->
      Agent.get_and_update(agent, fn
        [last] -> {last, [last]}
        [next | rest] -> {next, rest}
      end)
    end)
  end

  defp live_build(attrs \\ []) do
    row = agent_session(Keyword.merge([name: "out-build", pane_id: "%8"], attrs))
    {:ok, row, _} = Foreman.AgentSessions.fire(row, :output_changed)
    row
  end

  describe "live pane" do
    test "loading shows the skeleton, then the converted output", %{conn: conn} do
      screens([{@screen, 0}])
      row = live_build()
      {:ok, view, html} = live(conn, "/sessions/#{row.id}")

      assert html =~ "Reading the terminal…"
      assert_receive {:tmux, ~w(-N -L default capture-pane -p -e -J -S -200 -t %8)}
      render_async(view)

      refute has_element?(view, "#session-output-loading")
      assert has_element?(view, "#session-output-body .bb-term-b", "bash")
      assert has_element?(view, "#session-output-body .bb-term-fg-1", "red")

      assert has_element?(
               view,
               "#session-output-body a[href='https://hexdocs.pm/x'][rel='noopener noreferrer']",
               "docs"
             )
    end

    test "each tick reads again and new output replaces the old", %{conn: conn} do
      screens([{"first\n", 0}, {"second\n", 0}])
      row = live_build()
      {:ok, view, _} = live(conn, "/sessions/#{row.id}")
      assert_receive {:tmux, _}
      render_async(view)
      assert has_element?(view, "#session-output-body", "first")

      send(view.pid, :pane_tick)
      assert_receive {:tmux, _}
      render_async(view)
      assert has_element?(view, "#session-output-body", "second")
    end

    test "the latest output is saved as the last-check fallback", %{conn: conn} do
      screens([{"kept for later\n", 0}])
      row = live_build()
      {:ok, view, _} = live(conn, "/sessions/#{row.id}")
      assert_receive {:tmux, _}
      render_async(view)
      assert %{reason: "poll", output: "kept for later\n"} = SessionCaptures.get(row.id)
    end

    test "a hidden browser tab stops reading; showing it reads again", %{conn: conn} do
      screens([{"one\n", 0}])
      row = live_build()
      {:ok, view, _} = live(conn, "/sessions/#{row.id}")
      assert_receive {:tmux, _}
      render_async(view)

      view
      |> element("#session-output")
      |> render_hook("output-visibility", %{"visible" => false})

      send(view.pid, :pane_tick)
      render(view)
      refute_receive {:tmux, _}, 100

      view |> element("#session-output") |> render_hook("output-visibility", %{"visible" => true})
      assert_receive {:tmux, _}
      render_async(view)
    end

    test "another tab stops reading", %{conn: conn} do
      screens([{"one\n", 0}])
      row = live_build()
      {:ok, view, _} = live(conn, "/sessions/#{row.id}")
      assert_receive {:tmux, _}
      render_async(view)

      view |> element("#session-tab-timeline") |> render_click()
      send(view.pid, :pane_tick)
      render(view)
      refute_receive {:tmux, _}, 100
      refute has_element?(view, "#session-output")
    end

    test "a pane with only blank lines shows No output yet.", %{conn: conn} do
      screens([{"\n   \n\e[0m\n", 0}])
      row = live_build()
      {:ok, view, _} = live(conn, "/sessions/#{row.id}")
      assert_receive {:tmux, _}
      render_async(view)
      assert has_element?(view, "#session-output-empty", "No output yet.")
    end

    test "tmux error shows the head line and Try again now", %{conn: conn} do
      screens([{"no server running", 1}])
      row = live_build()
      {:ok, view, _} = live(conn, "/sessions/#{row.id}")
      assert_receive {:tmux, _}
      render_async(view)

      assert has_element?(
               view,
               "#session-output-error",
               "Cannot read the terminal: tmux does not answer."
             )

      view |> element("#session-output-retry") |> render_click()
      assert_receive {:tmux, _}
      render_async(view)
      assert has_element?(view, "#session-output-retry-result", "tmux still does not answer.")
    end

    test "output comes back after a tmux error", %{conn: conn} do
      screens([{"no server running", 1}, {"back\n", 0}])
      row = live_build()
      {:ok, view, _} = live(conn, "/sessions/#{row.id}")
      assert_receive {:tmux, _}
      render_async(view)
      assert has_element?(view, "#session-output-error")

      view |> element("#session-output-retry") |> render_click()
      assert_receive {:tmux, _}
      render_async(view)
      refute has_element?(view, "#session-output-error")
      assert has_element?(view, "#session-output-body", "back")
    end

    test "the page stops reading when the session ends", %{conn: conn} do
      screens([{"one\n", 0}])
      row = live_build()
      {:ok, view, _} = live(conn, "/sessions/#{row.id}?tab=output")
      assert_receive {:tmux, _}
      render_async(view)

      Foreman.AgentSessions.end_session(row)
      send(view.pid, {:notification, :foreman_events, %{kind: "sessions_changed"}})
      send(view.pid, :pane_tick)
      render(view)
      refute_receive {:tmux, _}, 100
      assert has_element?(view, "#session-output-head", "from the last check")
    end
  end

  describe "dead view" do
    for {reason, line} <- [
          exit: "when the pane closed",
          poll: "from the last check",
          stop: "when you pressed Stop",
          park: "when the session was parked"
        ] do
      test "saved at #{reason}: head line and output", %{conn: conn} do
        tmux(fn _ -> flunk("a dead session is never read") end)

        row =
          agent_session(kind: if(unquote(reason) == :park, do: "epic_coordinator", else: "build"))

        {:ok, _} = SessionCaptures.save(row.id, "\e[32mlast words\e[0m\n", unquote(reason))
        {:ok, row, _} = Foreman.AgentSessions.fire(row, :output_changed)

        {:ok, row, _} =
          Foreman.AgentSessions.fire(row, if(unquote(reason) == :park, do: :park, else: :stop))

        {:ok, view, _} = live(conn, "/sessions/#{row.id}?tab=output")
        assert has_element?(view, "#session-output-head", "Saved")
        assert has_element?(view, "#session-output-head", unquote(line))
        assert has_element?(view, "#session-output-head time[title]")
        assert has_element?(view, "#session-output-body .bb-term-fg-2", "last words")
        refute_received {:tmux, _}
      end
    end

    test "nothing saved", %{conn: conn} do
      tmux(fn _ -> flunk("a dead session is never read") end)
      row = agent_session() |> Foreman.AgentSessions.end_session()
      {:ok, view, _} = live(conn, "/sessions/#{row.id}?tab=output")
      assert has_element?(view, "#session-output-empty", "No output was saved for this session.")
      refute has_element?(view, "#session-output-head")
    end
  end
end
