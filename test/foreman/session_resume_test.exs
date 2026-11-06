defmodule Foreman.SessionResumeTest do
  @moduledoc """
  The ended-session controls and answers to ended sessions (spec Decisions 17 dead rows,
  20, R4, R8, R9, R10): which show with which off reasons, what Resume, Relaunch build and
  Start fresh do to tmux and the rows, and where an answer goes. tmux is a stand-in that
  records every call; no test starts a real Claude or Pi.
  """
  use Foreman.DataCase, async: false
  import Foreman.AgentSessionFixtures
  alias Foreman.{AgentSessions, Repo, RequestSource, Requests, SessionControls, SessionResume}

  setup do
    root = Path.join(System.tmp_dir!(), "ec-resume-#{System.unique_integer([:positive])}")
    sessions = Path.join(root, "pi-sessions")
    File.mkdir_p!(sessions)
    Application.put_env(:foreman, :pi_sessions_dir, sessions)

    on_exit(fn ->
      Application.delete_env(:foreman, :pi_sessions_dir)
      File.rm_rf(root)
    end)

    # Stub executables: the launcher resolves them to absolute paths; nothing runs them here.
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)

    for name <- ~w(pi claude) do
      File.write!(Path.join(bin, name), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(bin, name), 0o700)
    end

    executables = %{"pi" => Path.join(bin, "pi"), "claude" => Path.join(bin, "claude")}
    %{root: root, sessions: sessions, executables: executables}
  end

  defp worktree(ctx, name) do
    dir = Path.join(ctx.root, name)
    File.mkdir_p!(dir)
    dir
  end

  # The Pi session file `AgentSessions.resumable?/1` looks for.
  defp pi_file(ctx, dir, id) do
    project = "--" <> (dir |> String.trim_leading("/") |> String.replace("/", "-")) <> "--"
    File.mkdir_p!(Path.join(ctx.sessions, project))
    File.write!(Path.join([ctx.sessions, project, "2026-11-05_" <> id <> ".jsonl"]), "{}\n")
  end

  defp coordinator(attrs \\ %{}),
    do:
      agent_session(
        Map.merge(
          %{name: "fm-epic", kind: "epic_coordinator", harness: "claude", pane_id: "%1"},
          attrs
        )
      )

  defp ended(row), do: AgentSessions.end_session(row)

  defp resumable_build(ctx, parent, attrs \\ %{}) do
    dir = worktree(ctx, Map.get(attrs, :name, "build-a"))
    id = Ecto.UUID.generate()
    pi_file(ctx, dir, id)

    agent_session(
      Map.merge(
        %{
          name: "build-a",
          parent_id: parent && parent.id,
          conversation_id: id,
          workdir: dir,
          pane_id: "%5",
          project: "foreman",
          ticket: "fm-9mm.15",
          branch: "feat/a"
        },
        attrs
      )
    )
  end

  # A stand-in tmux: list-panes answers `panes` (`{pane, session, name}`), new panes are
  # `%42`, and every call is sent to the test.
  defp runner(panes, fail \\ []) do
    test = self()

    listing =
      Enum.map_join(panes, "\n", fn {pane, session, name} ->
        Enum.join([pane, "@1", session, name, "1", "", "", "1", "2", "0", "0,0"], "\t")
      end)

    fn "tmux", args, _ ->
      send(test, {:tmux, args})
      command = Enum.find(args, &(&1 in ~w(list-panes new-window new-session split-window)))

      cond do
        command in fail -> {"failed", 1}
        command == "list-panes" -> {listing, 0}
        command in ~w(new-window new-session split-window) -> {"%42\n", 0}
        true -> {"", 0}
      end
    end
  end

  # The launch line is quoted once more for `$SHELL -ilc`.
  defp line(argv), do: String.replace(argv, "'", "'\\''")

  defp calls do
    receive do
      {:tmux, args} -> [args | calls()]
    after
      0 -> []
    end
  end

  defp opened(calls),
    do: Enum.find(calls, &Enum.any?(&1, fn a -> a in ~w(new-window new-session split-window) end))

  defp opts(ctx, panes, fail \\ []),
    do: [runner: runner(panes, fail), executables: ctx.executables]

  defp off(controls, control) do
    case List.keyfind(controls, control, 0) do
      {_, {:off, reason}} -> reason
      _ -> nil
    end
  end

  defp on?(controls, control), do: List.keyfind(controls, control, 0) == {control, :on}
  defp names(controls), do: Enum.map(controls, &elem(&1, 0))

  describe "controls/2: the dead rows of Decision 17" do
    test "a live session lists no dead control", ctx do
      row = resumable_build(ctx, nil)

      refute Enum.any?(
               names(SessionControls.controls(row)),
               &(&1 in [:resume, :relaunch_build, :start_fresh])
             )
    end

    test "an ended build that can resume offers Resume only (R4)", ctx do
      c = SessionControls.controls(ended(resumable_build(ctx, coordinator())))
      assert on?(c, :resume)
      refute List.keymember?(c, :relaunch_build, 0)
      refute List.keymember?(c, :start_fresh, 0)
      assert off(c, :stop) == "The pane is closed."
    end

    test "an ended Pi build with no session id: Resume off, Relaunch build on", ctx do
      parent = coordinator()
      row = ended(agent_session(name: "b", parent_id: parent.id, workdir: worktree(ctx, "b")))
      c = SessionControls.controls(row)
      assert off(c, :resume) == "No Pi session id was recorded at launch."
      assert on?(c, :relaunch_build)
      refute List.keymember?(c, :start_fresh, 0)
    end

    test "an ended Pi build whose worktree is gone", ctx do
      row = resumable_build(ctx, coordinator())
      File.rm_rf!(row.workdir)
      c = SessionControls.controls(ended(row))
      assert off(c, :resume) == "The worktree was removed."
      assert on?(c, :relaunch_build)
    end

    test "an ended build whose coordinator ended too: Relaunch build on when it can resume (R8)",
         ctx do
      parent = coordinator(%{conversation_id: Ecto.UUID.generate()}) |> ended()
      row = ended(agent_session(name: "b", parent_id: parent.id, workdir: worktree(ctx, "b")))
      assert on?(SessionControls.controls(row), :relaunch_build)

      stuck = coordinator(%{name: "fm-stuck"}) |> ended()
      row = ended(agent_session(name: "c", parent_id: stuck.id))

      assert off(SessionControls.controls(row), :relaunch_build) ==
               "fm-stuck ended and cannot resume."
    end

    test "an ended build with no coordinator cannot be relaunched" do
      row = ended(agent_session(name: "b"))

      assert off(SessionControls.controls(row), :relaunch_build) ==
               "No coordinator is recorded for it."
    end

    test "a parked coordinator with a conversation id offers Resume" do
      row = coordinator(%{conversation_id: Ecto.UUID.generate()})
      {:ok, row, _} = AgentSessions.fire(row, :park)
      c = SessionControls.controls(row)
      assert on?(c, :resume)
      refute List.keymember?(c, :start_fresh, 0)
    end

    test "an ended coordinator with no conversation id offers Start fresh (R4)" do
      c = SessionControls.controls(ended(coordinator()))
      assert off(c, :resume) == "The board has no conversation id for it."
      assert on?(c, :start_fresh)
      refute List.keymember?(c, :relaunch_build, 0)
    end
  end

  describe "resume/2" do
    test "a Pi build next to its live coordinator: a new pane in the coordinator's window, same row",
         ctx do
      parent = coordinator()
      row = ended(resumable_build(ctx, parent))
      panes = [{"%1", "foreman", "fm-epic"}]

      assert {:ok, resumed} = SessionResume.resume(row, opts(ctx, panes))
      assert resumed.id == row.id
      assert %{state: "starting", ended_at: nil, pane_id: "%42"} = resumed

      calls = calls()

      assert [
               "-N",
               "-L",
               "default",
               "split-window",
               "-d",
               "-h",
               "-t",
               "%1",
               "-P",
               "-F",
               _,
               "-c",
               dir,
               command
             ] =
               opened(calls)

      assert dir == row.workdir

      assert command =~
               line(~s('#{ctx.executables["pi"]}' '--session-id' '#{row.conversation_id}'))

      assert command =~ "FOREMAN_SESSION='\\''build-a'\\''"
      assert command =~ "FOREMAN_PARENT='\\''fm-epic'\\''"

      assert ["-N", "-L", "default", "set-option", "-p", "-t", "%42", "@build", "build-a"] in calls
    end

    test "a Pi build whose coordinator is dead: a new window with its name in the project's session",
         ctx do
      parent = coordinator() |> ended()
      row = ended(resumable_build(ctx, parent))

      assert {:ok, %{pane_id: "%42"}} =
               SessionResume.resume(row, opts(ctx, [{"%3", "foreman", "keeper"}]))

      assert ["-N", "-L", "default", "new-window", "-d", "-t", "=foreman:", "-n", "build-a" | _] =
               opened(calls())
    end

    test "with no session for the project, a new tmux session", ctx do
      row = ended(resumable_build(ctx, nil))
      assert {:ok, _} = SessionResume.resume(row, opts(ctx, []))

      assert ["-N", "-L", "default", "new-session", "-d", "-s", "foreman", "-n", "build-a" | _] =
               opened(calls())
    end

    test "a Claude coordinator resumes its conversation with --resume in its workdir", ctx do
      id = Ecto.UUID.generate()
      dir = worktree(ctx, "coord")

      row =
        coordinator(%{conversation_id: id, workdir: dir, model: "claude-opus-5-5"}) |> ended()

      assert {:ok, %{id: same, pane_id: "%42"}} = SessionResume.resume(row, opts(ctx, []))
      assert same == row.id
      [_ | _] = args = opened(calls())
      assert Enum.at(args, -2) == dir

      assert List.last(args) =~
               line(
                 ~s('#{ctx.executables["claude"]}' '--model' 'claude-opus-5-5' '--resume' '#{id}')
               )
    end

    test "a failed open leaves the row ended", ctx do
      row = ended(resumable_build(ctx, nil))

      assert SessionResume.resume(row, opts(ctx, [], ["new-session"])) ==
               {:error, :tmux_unavailable}

      assert %{state: "ended", pane_id: "%5"} = AgentSessions.get(row.id)
    end

    test "an old pane that is still open is not resumed a second time", ctx do
      row = ended(resumable_build(ctx, nil))

      assert SessionResume.resume(row, opts(ctx, [{"%5", "foreman", "build-a"}])) ==
               {:error, :still_open}

      assert opened(calls()) == nil
      assert %{state: "ended"} = AgentSessions.get(row.id)
    end

    test "a coordinator whose workdir is gone cannot start fresh", ctx do
      old = coordinator(%{workdir: Path.join(ctx.root, "gone")}) |> ended()
      assert SessionResume.start_fresh(old, opts(ctx, [])) == {:error, :workdir_gone}
    end

    test "a session that cannot resume is refused before tmux", ctx do
      row = ended(agent_session(name: "b", workdir: worktree(ctx, "b")))
      assert SessionResume.resume(row, opts(ctx, [])) == {:error, :invalid}
      assert calls() == []
    end

    test "another live session with the name keeps it (R7)", ctx do
      row = ended(resumable_build(ctx, nil))
      _other = agent_session(name: "build-a", pane_id: "%8")
      assert SessionResume.resume(row, opts(ctx, [])) == {:error, :name_taken}
      assert opened(calls()) == nil
    end

    test "the preview refuses it", ctx do
      row = ended(resumable_build(ctx, nil))
      System.put_env("PREVIEW", "1")
      on_exit(fn -> System.delete_env("PREVIEW") end)
      assert SessionResume.resume(row, opts(ctx, [])) == {:error, "refused in preview"}
      assert calls() == []
    end
  end

  describe "relaunch_build/2" do
    test "a live coordinator gets the relaunch note in its pane" do
      parent = coordinator()

      row =
        ended(
          agent_session(name: "b", parent_id: parent.id, ticket: "fm-9mm.15", branch: "feat/b")
        )

      test = self()

      runner = fn "tmux", args, _ ->
        send(test, {:tmux, args})

        cond do
          "list-panes" in args -> {"%1\t@1\tforeman\tfm-epic\t1\n", 0}
          "capture-pane" in args -> {"───\n❯ \n───\n", 0}
          true -> {"", 0}
        end
      end

      assert {:ok, %{coordinator: "fm-epic", resumed: false}} =
               SessionResume.relaunch_build(row, runner: runner, key_delay: 0)

      typed = for args <- calls(), "-l" in args, do: List.last(args)

      assert typed == [
               "[foreman note from board] Relaunch the build for fm-9mm.15 on feat/b."
             ]

      assert %{state: "ended"} = AgentSessions.get(row.id)
    end

    test "R8: a dead coordinator resumes first, with the note as its first message", ctx do
      dir = worktree(ctx, "coord")
      parent = coordinator(%{conversation_id: Ecto.UUID.generate(), workdir: dir}) |> ended()

      row =
        ended(
          agent_session(name: "b", parent_id: parent.id, ticket: "fm-9mm.15", branch: "feat/b")
        )

      assert {:ok, %{coordinator: "fm-epic", resumed: true}} =
               SessionResume.relaunch_build(row, opts(ctx, []))

      assert List.last(opened(calls())) =~
               line(
                 ~s('--resume' '#{parent.conversation_id}' '[foreman note from board] Relaunch the build for fm-9mm.15 on feat/b.')
               )

      assert %{state: "starting", pane_id: "%42"} = AgentSessions.get(parent.id)
      assert %{state: "ended"} = AgentSessions.get(row.id)
    end

    test "a coordinator that cannot resume takes nothing; nothing changes", ctx do
      parent = coordinator() |> ended()
      row = ended(agent_session(name: "b", parent_id: parent.id))

      assert SessionResume.relaunch_build(row, opts(ctx, [])) ==
               {:error, {:coordinator, "fm-epic", :coordinator_not_resumable}}

      assert opened(calls()) == nil
    end

    test "a build that can resume is not relaunched (R4)", ctx do
      row = ended(resumable_build(ctx, coordinator()))
      assert SessionResume.relaunch_build(row, opts(ctx, [])) == {:error, :invalid}
    end
  end

  describe "start_fresh/2" do
    test "a new row with the same name and parent; live builds move; the old row stays", ctx do
      main = agent_session(name: "coordinator", kind: "main_coordinator", harness: "claude")
      dir = worktree(ctx, "epic")
      old = coordinator(%{parent_id: main.id, workdir: dir, model: "claude-opus-5-5"})
      live_build = agent_session(name: "live-b", parent_id: old.id, pane_id: "%7")
      dead_build = agent_session(name: "dead-b", parent_id: old.id) |> ended()
      old = ended(old)

      assert {:ok, new} = SessionResume.start_fresh(old, opts(ctx, []))

      assert %{name: "fm-epic", kind: "epic_coordinator", harness: "claude", state: "starting"} =
               new

      assert new.id != old.id
      assert new.parent_id == main.id
      assert new.conversation_id == new.id
      assert new.pane_id == "%42"
      assert new.workdir == dir

      assert AgentSessions.get(live_build.id).parent_id == new.id
      assert AgentSessions.get(dead_build.id).parent_id == old.id
      assert %{state: "ended", ended_at: %DateTime{}} = AgentSessions.get(old.id)

      assert List.last(opened(calls())) =~
               line(~s('--model' 'claude-opus-5-5' '--session-id' '#{new.id}' '/orient'))
    end

    test "a coordinator that can resume is not started fresh", ctx do
      old = coordinator(%{conversation_id: Ecto.UUID.generate()}) |> ended()
      assert SessionResume.start_fresh(old, opts(ctx, [])) == {:error, :invalid}
    end

    test "a failed open makes no row and moves nothing", ctx do
      old = coordinator(%{workdir: worktree(ctx, "epic")})
      build = agent_session(name: "live-b", parent_id: old.id, pane_id: "%7")
      old = ended(old)

      assert SessionResume.start_fresh(old, opts(ctx, [], ["new-session"])) ==
               {:error, :tmux_unavailable}

      assert AgentSessions.live_by_name("fm-epic") == nil
      assert AgentSessions.get(build.id).parent_id == old.id
    end
  end

  describe "R9: answers to the card of an ended session" do
    defp card(row, question \\ "Keep the confirm in the page?") do
      %Foreman.Requests.Request{
        repo_key: "foreman",
        bead_id: "fm-9mm.15",
        kind: "decision",
        actor: "pi",
        state: "pending",
        session: row.name,
        facts: %{"question" => question, "options" => ["Keep it", "Drop it"]}
      }
      |> Repo.insert!()
      |> asked_by(row)
    end

    defp with_tmux(opts) do
      Application.put_env(:foreman, :session_controls_tmux, opts)

      on_exit(fn ->
        Application.put_env(:foreman, :session_controls_tmux,
          runner: &Foreman.TestTmux.no_panes/3
        )
      end)
    end

    test "routes: live, resume, note to the coordinator, or nowhere", ctx do
      parent = coordinator()
      assert SessionResume.answer_route(card(agent_session(name: "live-b"))) == :live
      resumable = ended(resumable_build(ctx, parent))
      assert {:resume, %{id: id}} = SessionResume.answer_route(card(resumable))
      assert id == resumable.id
      stuck = ended(agent_session(name: "stuck", parent_id: parent.id))
      assert {:note, %{id: pid}} = SessionResume.answer_route(card(stuck))
      assert pid == parent.id

      main =
        agent_session(name: "coordinator", kind: "main_coordinator", harness: "claude") |> ended()

      assert SessionResume.answer_route(card(main)) == :none
    end

    test "the card source row says where the answer goes", ctx do
      parent = coordinator()
      stuck = ended(agent_session(name: "stuck", parent_id: parent.id))
      assert %{receiver: "fm-epic", resumes: false} = RequestSource.view(card(stuck))

      resumable = ended(resumable_build(ctx, parent))
      assert %{receiver: nil, resumes: true} = RequestSource.view(card(resumable))

      answered = %{card(stuck) | state: "answered"}
      assert %{receiver: nil, resumes: false} = RequestSource.view(answered)
    end

    test "the coordinator of a session that took the dead parent's name gets it" do
      old = coordinator() |> ended()
      stuck = ended(agent_session(name: "stuck", parent_id: old.id))
      new = coordinator(%{pane_id: "%2"})
      assert {:note, %{id: id}} = SessionResume.answer_route(card(stuck))
      assert id == new.id
    end

    test "a build that cannot resume: the coordinator gets the question and the answer, the card closes (acceptance 9)" do
      parent = coordinator()
      row = agent_session(name: "stuck", parent_id: parent.id, pane_id: "%5")
      request = card(row)
      {:ok, row, _} = AgentSessions.fire(row, :asked)
      {:ok, _, _} = AgentSessions.fire(row, :stop)
      test = self()

      with_tmux(
        runner: fn "tmux", args, _ ->
          send(test, {:tmux, args})

          cond do
            "list-panes" in args -> {"%1\t@1\tforeman\tfm-epic\t1\n", 0}
            "capture-pane" in args -> {"───\n❯ \n───\n", 0}
            true -> {"", 0}
          end
        end,
        key_delay: 0
      )

      assert {:ok, %{state: "answered"}} =
               Requests.resolve(request.id, :answer, %{
                 "answer" => "Keep it",
                 "note" => "and say why"
               })

      seen = calls()
      [typed] = for args <- seen, "-l" in args, do: List.last(args)

      assert typed ==
               "[foreman note from board] stuck ended and cannot resume. Ryan answered its card #{request.id}. " <>
                 "Question: Keep the confirm in the page? Answer: Keep it Note: and say why " <>
                 "Full outcome: foreman wait #{request.id}"

      # Typed into the coordinator's pane only.
      assert ["-N", "-L", "default", "send-keys", "-t", "%1", "-l", "--", typed] in seen
    end

    test "a coordinator that is busy: the answer is saved and the note waits for it (fm-9mm.23)" do
      parent = coordinator()
      row = ended(agent_session(name: "stuck", parent_id: parent.id))
      request = card(row)
      test = self()

      with_tmux(
        runner: fn "tmux", args, _ ->
          send(test, {:tmux, args})

          cond do
            "list-panes" in args -> {"%1\t@1\tforeman\tfm-epic\t1\n", 0}
            "capture-pane" in args -> {"✳ Working… (3s)\n───\n❯ \n───\nesc to interrupt\n", 0}
            true -> {"", 0}
          end
        end,
        key_delay: 0
      )

      assert {:ok, %{state: "answered"}} =
               Requests.resolve(request.id, :answer, %{"answer" => "Keep it"})

      assert [] = for(args <- calls(), "send-keys" in args, do: args)

      assert %{state: "queued", coordinator_id: coordinator_id, subject_id: subject_id} =
               Foreman.QueuedNotes.for_request(request.id)

      assert {coordinator_id, subject_id} == {parent.id, row.id}
    end

    test "a coordinator whose pane is gone: the answer is refused and the card stays open" do
      parent = coordinator()
      row = ended(agent_session(name: "stuck", parent_id: parent.id))
      request = card(row)
      with_tmux(runner: fn "tmux", _, _ -> {"", 0} end, key_delay: 0)

      assert Requests.resolve(request.id, :answer, %{"answer" => "Keep it"}) ==
               {:error, {:not_delivered, "fm-epic", :window_gone}}

      assert %{state: "pending"} = Requests.get(request.id)
      assert Foreman.QueuedNotes.for_request(request.id) == nil
    end

    test "a session that can resume: the board resumes it with the answer as its first message",
         ctx do
      row = resumable_build(ctx, nil)
      request = card(row)
      row = ended(row)
      with_tmux(runner: runner([]), executables: ctx.executables)

      assert {:ok, %{state: "answered"}} =
               Requests.resolve(request.id, :answer, %{"answer" => "Drop it"})

      command = List.last(opened(calls()))

      assert command =~
               line(
                 "'--session-id' '#{row.conversation_id}' '[foreman note from board] Ryan answered your card #{request.id}"
               )

      assert command =~ "Answer: Drop it"
      assert %{state: "starting", pane_id: "%42"} = AgentSessions.get(row.id)
    end

    test "a failed resume refuses the answer and leaves the session ended", ctx do
      row = resumable_build(ctx, nil)
      request = card(row)
      row = ended(row)
      with_tmux(runner: runner([], ["new-session"]), executables: ctx.executables)

      assert Requests.resolve(request.id, :answer, %{"answer" => "Drop it"}) ==
               {:error, {:not_delivered, "build-a", :tmux_unavailable}}

      assert %{state: "pending"} = Requests.get(request.id)
      assert %{state: "ended"} = AgentSessions.get(row.id)
    end

    test "a main coordinator with no one to take the note: the answer is only saved" do
      main = agent_session(name: "coordinator", kind: "main_coordinator", harness: "claude")
      request = card(main)
      ended(main)

      assert {:ok, %{state: "answered"}} =
               Requests.resolve(request.id, :answer, %{"answer" => "Keep it"})
    end
  end

  describe "on a scratch tmux server, with stub executables" do
    # Each stub writes its argv, working directory and identity to a file, then signals the
    # test and sleeps: no real agent runs.
    setup ctx do
      socket = Foreman.TestTmux.socket("ec-resume")

      tmux = fn args ->
        System.cmd("tmux", ["-L", socket, "-f", "/dev/null" | args], env: [{"SHELL", "/bin/sh"}])
      end

      bin = Path.join(ctx.root, "stubs")
      File.mkdir_p!(bin)

      stubs =
        for name <- ~w(pi claude), into: %{} do
          path = Path.join(bin, name)

          File.write!(path, """
          #!/bin/sh
          out=#{ctx.root}/#{name}.txt
          printf '%s\\n' "$@" > "$out"
          printf 'PWD=%s\\nSESSION=%s\\nPARENT=%s\\nACTOR=%s\\n' "$PWD" "$FOREMAN_SESSION" "$FOREMAN_PARENT" "$FOREMAN_ACTOR" >> "$out"
          tmux wait-for -S #{name}-#{socket}
          exec sleep 60
          """)

          File.chmod!(path, 0o700)
          {name, path}
        end

      {coord, 0} =
        tmux.(
          ~w(new-session -d -s foreman -n fm-epic -x 120 -y 30 -P -F #{"\#{pane_id}"} sleep 60)
        )

      tmux.(~w(set-option -g default-shell /bin/sh))
      Application.put_env(:foreman, :external_tmux_socket, socket)
      on_exit(fn -> Application.delete_env(:foreman, :external_tmux_socket) end)

      %{socket: socket, tmux: tmux, stubs: stubs, coord: String.trim(coord)}
    end

    defp wait_for(ctx, name) do
      task = Task.async(fn -> ctx.tmux.(["wait-for", "#{name}-#{ctx.socket}"]) end)
      assert {_, 0} = Task.await(task, 15_000)
      File.read!(Path.join(ctx.root, name <> ".txt")) |> String.split("\n", trim: true)
    end

    test "Pi: --session-id in its worktree, in a new pane of the live coordinator's window",
         ctx do
      parent = coordinator(%{pane_id: ctx.coord})
      row = ended(resumable_build(ctx, parent))

      assert {:ok, %{pane_id: pane}} =
               SessionResume.resume(row, runner: &System.cmd/3, executables: ctx.stubs)

      lines = wait_for(ctx, "pi")
      assert ["--session-id", id | _] = lines
      assert id == row.conversation_id
      assert "SESSION=build-a" in lines and "PARENT=fm-epic" in lines and "ACTOR=pi" in lines
      [pwd] = for "PWD=" <> dir <- lines, do: dir
      assert File.stat!(pwd).inode == File.stat!(row.workdir).inode

      {out, 0} =
        ctx.tmux.(["list-panes", "-t", "foreman:fm-epic", "-F", "\#{pane_id} \#{@build}"])

      assert "#{pane} build-a" in String.split(out, "\n", trim: true)
      assert "#{ctx.coord} " in String.split(out, "\n", trim: true)
    end

    test "Claude: --resume <id> in its workdir, in a new window with its name", ctx do
      dir = worktree(ctx, "coord")

      row =
        coordinator(%{name: "fm-other", conversation_id: Ecto.UUID.generate(), workdir: dir})
        |> ended()

      assert {:ok, %{pane_id: pane}} =
               SessionResume.resume(row, runner: &System.cmd/3, executables: ctx.stubs)

      lines = wait_for(ctx, "claude")
      assert ["--resume", id | _] = lines
      assert id == row.conversation_id
      assert "SESSION=fm-other" in lines and "ACTOR=claude" in lines

      {name, 0} = ctx.tmux.(~w(display-message -p -t #{pane} #{"\#{window_name}"}))
      assert String.trim(name) == "fm-other"
    end
  end
end
