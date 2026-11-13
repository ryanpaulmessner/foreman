defmodule ForemanWeb.SessionEndedControlsLiveTest do
  @moduledoc """
  The session page's dead panel states and controls (spec Decision 17 dead rows, the copy
  table's dead states, R4, R8, R9), through the page's element ids. tmux is a stand-in;
  no test starts a real Claude or Pi.
  """
  use ForemanWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Foreman.AgentSessionFixtures
  alias Foreman.AgentSessions

  setup do
    root = Path.join(System.tmp_dir!(), "ec-page-#{System.unique_integer([:positive])}")
    sessions = Path.join(root, "pi-sessions")
    File.mkdir_p!(sessions)
    Application.put_env(:foreman, :pi_sessions_dir, sessions)

    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)

    for name <- ~w(pi claude) do
      File.write!(Path.join(bin, name), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(bin, name), 0o700)
    end

    on_exit(fn ->
      Application.delete_env(:foreman, :pi_sessions_dir)
      Application.put_env(:foreman, :session_controls_tmux, runner: &Foreman.TestTmux.no_panes/3)
      File.rm_rf(root)
    end)

    %{
      root: root,
      sessions: sessions,
      executables: %{"pi" => Path.join(bin, "pi"), "claude" => Path.join(bin, "claude")}
    }
  end

  # A stand-in tmux: `panes` are `{pane, session, window}`; Claude's prompt is idle; a new
  # pane is `%42`. `fail` names commands that fail.
  defp tmux(ctx, panes, fail \\ []) do
    test = self()

    runner = fn "tmux", args, _ ->
      send(test, {:tmux, args})

      command =
        Enum.find(
          args,
          &(&1 in ~w(list-panes capture-pane send-keys new-window new-session split-window))
        )

      format = Enum.find(args, "", &String.contains?(&1, "pane_id"))

      cond do
        command in fail ->
          {"failed", 1}

        command == "list-panes" and format =~ "@build" ->
          {Enum.map_join(panes, "\n", fn {p, s, w} ->
             Enum.join([p, "@1", s, w, "1", "", "", "1", "2", "0", "0,0"], "\t")
           end), 0}

        command == "list-panes" ->
          {Enum.map_join(panes, "\n", fn {p, s, w} -> Enum.join([p, "@1", s, w, "1"], "\t") end),
           0}

        command == "capture-pane" ->
          {"───\n❯ \n───\n", 0}

        command in ~w(new-window new-session split-window) ->
          {"%42\n", 0}

        true ->
          {"", 0}
      end
    end

    Application.put_env(:foreman, :session_controls_tmux,
      runner: runner,
      key_delay: 0,
      executables: ctx.executables
    )
  end

  defp dir(ctx, name) do
    path = Path.join(ctx.root, name)
    File.mkdir_p!(path)
    path
  end

  defp pi_file(ctx, dir, id) do
    project = "--" <> (dir |> String.trim_leading("/") |> String.replace("/", "-")) <> "--"
    File.mkdir_p!(Path.join(ctx.sessions, project))
    File.write!(Path.join([ctx.sessions, project, "x_" <> id <> ".jsonl"]), "{}\n")
  end

  defp epic(attrs \\ %{}),
    do:
      agent_session(
        Map.merge(
          %{name: "fm-epic", kind: "epic_coordinator", harness: "claude", pane_id: "%1"},
          attrs
        )
      )

  defp build(ctx, name, parent, attrs \\ %{}) do
    agent_session(
      Map.merge(
        %{
          name: name,
          parent_id: parent && parent.id,
          workdir: dir(ctx, name),
          pane_id: "%5",
          ticket: "fm-9mm.15",
          branch: "feat/" <> name
        },
        attrs
      )
    )
  end

  defp resumable(ctx, name, parent) do
    id = Ecto.UUID.generate()
    row = build(ctx, name, parent, %{conversation_id: id})
    pi_file(ctx, row.workdir, id)
    row
  end

  defp ended(row), do: AgentSessions.end_session(row)

  defp card(row, question) do
    Foreman.Repo.insert!(%Foreman.Requests.Request{
      repo_key: "foreman",
      bead_id: "fm-9mm.15",
      kind: "decision",
      actor: "pi",
      state: "pending",
      agent_session_id: row.id,
      facts: %{"question" => question}
    })
  end

  defp open(conn, row) do
    {:ok, view, _} = live(conn, "/sessions/#{row.id}")
    view
  end

  describe "dead panel states (copy table)" do
    test "ended, can resume: Ended <time>, what ended it, [Resume]", %{conn: conn} = ctx do
      row = resumable(ctx, "build-a", epic())
      {:ok, row, _} = AgentSessions.fire(row, :stop)
      Foreman.SessionCaptures.save(row.id, "last\n", :stop)
      view = open(conn, row)

      assert has_element?(view, "#session-next-step h2", "Ended")
      assert has_element?(view, "#session-next-step time")
      assert has_element?(view, "#session-next-step", "You pressed Stop.")

      assert has_element?(
               view,
               "#session-next-step #session-control-resume[phx-disable-with='Resuming…']",
               "Resume"
             )

      refute has_element?(view, "#session-control-relaunch_build")
      refute has_element?(view, "#session-control-fresh_relaunch")
      refute has_element?(view, "#session-unavailable", "Resume")
      assert has_element?(view, "#session-unavailable", "(The pane is closed.)")
    end

    test "ended Pi build with no session id: [Relaunch build on this ticket]",
         %{conn: conn} = ctx do
      view = open(conn, ended(build(ctx, "build-b", epic())))

      assert has_element?(
               view,
               "#session-next-step",
               "This build cannot resume: No Pi session id was recorded at launch."
             )

      assert has_element?(
               view,
               "#session-next-step #session-control-relaunch_build[phx-disable-with='Relaunching…']",
               "Relaunch build on this ticket"
             )

      assert has_element?(
               view,
               "#session-unavailable",
               "Resume (No Pi session id was recorded at launch.)"
             )

      refute has_element?(view, "#session-control-resume")
    end

    test "ended Pi build whose worktree is gone", %{conn: conn} = ctx do
      row = resumable(ctx, "build-c", epic())
      File.rm_rf!(row.workdir)
      view = open(conn, ended(row))

      assert has_element?(
               view,
               "#session-next-step",
               "This build cannot resume: The worktree was removed."
             )

      assert has_element?(view, "#session-next-step #session-control-relaunch_build")
    end

    test "R8: its coordinator ended too and Relaunch resumes it first", %{conn: conn} = ctx do
      parent = epic(%{name: "fm-gone", conversation_id: Ecto.UUID.generate()})
      row = ended(build(ctx, "build-d", parent))
      ended(parent)
      view = open(conn, row)

      assert has_element?(
               view,
               "#session-next-step",
               "fm-gone ended"
             )

      assert has_element?(view, "#session-next-step", "too. Relaunch resumes fm-gone first.")
      refute has_element?(view, "#session-control-fresh_relaunch")
    end

    test "a build whose coordinator cannot resume offers chained recovery on its own page",
         %{conn: conn} = ctx do
      parent = epic(%{name: "fm-stuck"})
      row = ended(build(ctx, "build-e", parent))
      ended(parent)
      view = open(conn, row)
      assert has_element?(view, "#session-next-step", "too and cannot resume.")
      assert has_element?(view, "#session-control-fresh_relaunch")
      refute has_element?(view, "#session-control-relaunch_build")

      assert has_element?(
               view,
               "#session-unavailable",
               "Relaunch build on this ticket (fm-stuck ended and cannot resume.)"
             )
    end

    test "chained recovery is absent for live builds and builds with no coordinator",
         %{conn: conn} = ctx do
      parent = epic() |> ended()
      live_build = build(ctx, "still-working", parent)
      no_parent = build(ctx, "unassigned", nil) |> ended()

      for row <- [live_build, no_parent] do
        view = open(conn, row)
        refute has_element?(view, "#session-control-fresh_relaunch")
      end
    end

    test "chained recovery confirms both steps and saves the note for the new coordinator",
         %{conn: conn} = ctx do
      parent = epic(%{workdir: dir(ctx, "coord")}) |> ended()
      row = ended(build(ctx, "build-chain", parent))
      tmux(ctx, [])
      view = open(conn, row)
      view |> element("#session-control-fresh_relaunch") |> render_click()

      assert has_element?(
               view,
               "#session-fresh-question",
               "Start a new conversation for fm-epic?"
             )

      assert has_element?(
               view,
               "#session-fresh-confirm",
               "Relaunch the build for fm-9mm.15 on feat/build-chain."
             )

      assert has_element?(view, "#session-fresh-confirm-yes[phx-disable-with='Starting…']")
      view |> element("#session-fresh-confirm-yes") |> render_click()
      assert has_element?(view, "#session-result", "Started a new fm-epic conversation.")
      assert has_element?(view, "#session-note", "waits until its prompt is idle")
      new = AgentSessions.coordinator(AgentSessions.get(row.id))
      assert has_element?(view, "#session-result-link[href='/sessions/#{new.id}']")
      refute has_element?(view, "#session-control-fresh_relaunch")
      tmux(ctx, [{"%42", "foreman", "fm-epic"}])
      Foreman.QueuedNotes.run()
      send(view.pid, {:notification, :foreman_events, :sessions_changed})
      assert has_element?(view, "#session-note", "Sent fm-epic the relaunch note")
    end

    test "a failed fresh start says nothing changed and queues nothing", %{conn: conn} = ctx do
      parent = epic(%{workdir: dir(ctx, "coord")}) |> ended()
      row = ended(build(ctx, "build-chain", parent))
      tmux(ctx, [], ["new-session"])
      view = open(conn, row)
      view |> element("#session-control-fresh_relaunch") |> render_click()
      view |> element("#session-fresh-confirm-yes") |> render_click()

      assert has_element?(
               view,
               "#session-result",
               "Could not start a new conversation for fm-epic: tmux does not answer. Nothing changed."
             )

      assert Foreman.QueuedNotes.for_subject(row.id) == []
    end

    test "a coordinator that came back during confirmation is refused", %{conn: conn} = ctx do
      parent = epic(%{workdir: dir(ctx, "coord")}) |> ended()
      row = ended(build(ctx, "build-chain", parent))
      view = open(conn, row)
      view |> element("#session-control-fresh_relaunch") |> render_click()
      epic()
      view |> element("#session-fresh-confirm-yes") |> render_click()

      assert has_element?(
               view,
               "#session-result",
               "The coordinator is available again. Use Relaunch build on this ticket. Nothing changed."
             )

      assert Foreman.QueuedNotes.for_subject(row.id) == []
    end

    test "parked coordinator: Parked <time>, its builds keep running, [Resume]", %{conn: conn} do
      row = epic(%{name: "fm-parked", conversation_id: Ecto.UUID.generate()})
      {:ok, row, _} = AgentSessions.fire(row, :park)
      view = open(conn, row)
      assert has_element?(view, "#session-next-step h2", "Parked")
      assert has_element?(view, "#session-next-step", "Its builds keep running.")
      assert has_element?(view, "#session-next-step #session-control-resume")
    end

    test "dead coordinator, cannot resume: [Start fresh]", %{conn: conn} do
      view = open(conn, ended(epic(%{name: "fm-old"})))
      refute has_element?(view, "#session-control-fresh_relaunch")
      assert has_element?(view, "#session-next-step", "The board has no conversation id for it.")

      assert has_element?(
               view,
               "#session-next-step #session-control-start_fresh[phx-click='ask-fresh']",
               "Start fresh"
             )

      assert has_element?(
               view,
               "#session-unavailable",
               "Resume (The board has no conversation id for it.)"
             )
    end

    test "open card, cannot resume: the answer goes to the coordinator", %{conn: conn} = ctx do
      row = build(ctx, "build-f", epic())
      card = card(row, "Keep the confirm?")
      view = open(conn, ended(row))

      assert has_element?(view, "#session-next-step", "Its question is still open.")
      assert has_element?(view, "#session-next-step", "Keep the confirm?")

      assert has_element?(
               view,
               "#session-next-step",
               "When you answer, your answer and the question go to fm-epic as a note, and the card closes."
             )

      assert has_element?(view, "#session-answer[href='/needs-you#request-#{card.id}']")
      assert has_element?(view, "#session-controls #session-control-relaunch_build")
    end

    test "open card, can resume: the board resumes it first", %{conn: conn} = ctx do
      row = resumable(ctx, "build-g", epic())
      card(row, "Use the parent's window?")
      view = open(conn, ended(row))
      assert has_element?(view, "#session-state-second", "can resume")

      assert has_element?(
               view,
               "#session-next-step",
               "When you answer, the board resumes the session first."
             )

      assert has_element?(view, "#session-next-step #session-answer")
      assert has_element?(view, "#session-controls #session-control-resume")
    end
  end

  describe "results" do
    test "Resume: same page, the session lives again", %{conn: conn} = ctx do
      tmux(ctx, [])
      row = ended(resumable(ctx, "build-a", nil))
      view = open(conn, row)
      view |> element("#session-control-resume") |> render_click()

      assert has_element?(view, "#session-result", "Resumed build-a in #{row.workdir}.")
      assert %{state: "starting", pane_id: "%42"} = AgentSessions.get(row.id)
      refute has_element?(view, "#session-control-resume")
    end

    test "Relaunch build: the coordinator gets the note", %{conn: conn} = ctx do
      tmux(ctx, [{"%1", "foreman", "fm-epic"}])
      view = open(conn, ended(build(ctx, "build-b", epic())))
      view |> element("#session-control-relaunch_build") |> render_click()

      assert has_element?(
               view,
               "#session-result",
               ~s(Sent fm-epic the note: "Relaunch the build for fm-9mm.15 on feat/build-b.")
             )
    end

    test "Relaunch build with R8: resumed the coordinator and sent it the note",
         %{conn: conn} = ctx do
      tmux(ctx, [])

      parent =
        epic(%{name: "fm-gone", conversation_id: Ecto.UUID.generate(), workdir: dir(ctx, "c")})

      row = ended(build(ctx, "build-d", parent))
      ended(parent)
      view = open(conn, row)
      view |> element("#session-control-relaunch_build") |> render_click()
      assert has_element?(view, "#session-result", "Resumed fm-gone and sent it the note.")
      assert %{ended_at: nil} = AgentSessions.get(parent.id)
    end

    test "Start fresh: the in-page confirm, then a new conversation", %{conn: conn} = ctx do
      tmux(ctx, [])
      old = epic(%{name: "fm-old", workdir: dir(ctx, "old")})
      live_build = agent_session(name: "b-live", parent_id: old.id, pane_id: "%7")
      old = ended(old)
      view = open(conn, old)

      view |> element("#session-control-start_fresh") |> render_click()

      assert has_element?(
               view,
               "#session-fresh-confirm[role=alertdialog]",
               "Start a new conversation for fm-old?"
             )

      assert has_element?(
               view,
               "#session-fresh-confirm",
               "The old conversation stays in history."
             )

      assert has_element?(view, "#session-fresh-cancel[phx-mounted]", "Cancel")
      view |> element("#session-fresh-cancel") |> render_click()
      refute has_element?(view, "#session-fresh-confirm")

      view |> element("#session-control-start_fresh") |> render_click()

      assert has_element?(
               view,
               "#session-fresh-confirm-yes[phx-disable-with='Starting…']",
               "Start fresh"
             )

      view |> element("#session-fresh-confirm-yes") |> render_click()

      assert has_element?(
               view,
               "#session-result",
               "Started a new fm-old conversation. Its builds stay under it."
             )

      new = AgentSessions.live_by_name("fm-old")
      assert has_element?(view, "#session-result-link[href='/sessions/#{new.id}']")
      refute has_element?(view, "#session-fresh-confirm")
      assert AgentSessions.get(live_build.id).parent_id == new.id
      assert %{state: "ended"} = AgentSessions.get(old.id)
    end

    test "a failure says nothing changed", %{conn: conn} = ctx do
      tmux(ctx, [], ["new-session"])
      row = ended(resumable(ctx, "build-a", nil))
      view = open(conn, row)
      view |> element("#session-control-resume") |> render_click()

      assert has_element?(
               view,
               "#session-result[role=alert]",
               "Could not resume build-a: tmux does not answer. Nothing changed."
             )

      assert %{state: "ended"} = AgentSessions.get(row.id)
    end

    test "the preview refuses", %{conn: conn} = ctx do
      tmux(ctx, [])
      System.put_env("PREVIEW", "1")
      on_exit(fn -> System.delete_env("PREVIEW") end)
      view = open(conn, ended(build(ctx, "build-b", epic())))
      view |> element("#session-control-relaunch_build") |> render_click()

      assert has_element?(
               view,
               "#session-result",
               "Could not relaunch build-b: this preview does not write to tmux. Nothing changed."
             )
    end
  end
end
