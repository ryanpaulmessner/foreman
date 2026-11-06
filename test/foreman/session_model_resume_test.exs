defmodule Foreman.SessionModelResumeTest do
  use Foreman.DataCase, async: false
  import Foreman.AgentSessionFixtures
  alias Foreman.{AgentSessions, SessionCaptures, SessionModelResume}

  setup do
    root = Path.join(System.tmp_dir!(), "model-resume-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    bin = Path.join(root, "pi")
    File.write!(bin, "#!/bin/sh\nexit 0\n")
    File.chmod!(bin, 0o700)
    Application.put_env(:foreman, :pi_sessions_dir, root)
    id = Ecto.UUID.generate()

    dir =
      Path.join(
        root,
        "--" <> (root |> String.trim_leading("/") |> String.replace("/", "-")) <> "--"
      )

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "stamp_#{id}.jsonl"), "{}\n")

    row =
      agent_session(
        model: "openai-codex/gpt-6-astra",
        conversation_id: id,
        workdir: root,
        pane_id: "%5"
      )

    {:ok, row, _} = AgentSessions.fire(row, :usage_limit)

    on_exit(fn ->
      Application.delete_env(:foreman, :pi_sessions_dir)
      File.rm_rf!(root)
    end)

    %{row: row, bin: bin}
  end

  test "capture is saved, the recorded PID stops, and the same conversation resumes pinned on the fallback",
       ctx do
    state =
      start_supervised!(
        {Agent, fn -> %{stopped: false, root_stopped: false, pinned: false, calls: []} end}
      )

    base = runner(ctx, state)

    runner = fn exe, args, options ->
      if "capture-pane" in args and "%42" in args do
        refute Foreman.Repo.in_transaction?(),
               "Bifrost startup must not hold a database transaction"

        assert AgentSessions.get(ctx.row.id).pane_id == "%42"
      end

      base.(exe, args, options)
    end

    assert {:ok, resumed} =
             SessionModelResume.resume(ctx.row,
               runner: runner,
               executables: %{"pi" => ctx.bin},
               key_delay: 0,
               poll_delay: 0
             )

    assert resumed.id == ctx.row.id
    assert resumed.model == "anthropic/claude-opus-5-5"
    assert resumed.state == "starting"
    assert resumed.pane_id == "%42"
    assert SessionCaptures.get(resumed.id).output == "Usage limit reached"
    calls = Agent.get(state, & &1.calls)
    assert {"kill", ["-TERM", "102"]} in calls
    refute Enum.any?(calls, fn {_, args} -> "kill-pane" in args end)
    {_, launch} = Enum.find(calls, fn {_, args} -> "new-session" in args end)
    command = List.last(launch)
    assert command =~ ctx.row.conversation_id
    assert command =~ "--session-id"
    assert command =~ "--model"
    assert command =~ "anthropic/claude-opus-5-5"
    assert Agent.get(state, & &1.pinned)
  end

  test "a board Claude family fallback keeps planning identity and hooks", ctx do
    row =
      ctx.row
      |> Ecto.Changeset.change(
        harness: "claude",
        kind: "epic_coordinator",
        model: "claude-opus-5-5",
        tmux_server: "board"
      )
      |> Foreman.Repo.update!()

    Foreman.Repo.insert!(%Foreman.PlanningSession{
      session_id: row.id,
      agent_session_id: row.id,
      project: "scratch",
      ticket: "scratch-1",
      window: "@5",
      workdir: row.workdir,
      state: :waiting,
      launched_at: DateTime.utc_now()
    })

    Foreman.Repo.insert!(%Foreman.Requests.Request{
      repo_key: "scratch",
      bead_id: "scratch-1",
      kind: "session_waiting",
      actor: "claude",
      state: "pending",
      agent_session_id: row.id,
      facts: %{"reason" => "usage_limit", "limit_family" => "opus"}
    })

    state =
      start_supervised!(
        {Agent, fn -> %{stopped: false, root_stopped: false, pinned: false, calls: []} end}
      )

    ctx = %{ctx | row: row}

    assert {:ok, resumed} =
             SessionModelResume.resume(row,
               runner: runner(ctx, state),
               executables: %{"claude" => ctx.bin},
               poll_delay: 0
             )

    assert resumed.id == row.id
    assert resumed.model == "claude-sonnet-5-5"
    planning = Foreman.Repo.get!(Foreman.PlanningSession, row.id)
    assert planning.state == :starting
    assert planning.window == "@42"

    assert {:ok, _, _} =
             DateTime.from_iso8601(List.last(planning.previous_windows)["last_activity_at"])

    calls = Agent.get(state, & &1.calls)
    {_, args} = Enum.find(calls, fn {_, args} -> "new-session" in args end)
    command = List.last(args)
    assert command =~ "--resume"
    assert command =~ "--settings"
    assert command =~ "@foreman-state"
    assert command =~ "running"
    assert command =~ "ended"

    assert Enum.any?(calls, fn {_, args} ->
             "-u" in args and "@foreman-session" in args and "%5" in args
           end)

    assert command =~ "claude-sonnet-5-5"
    refute Enum.any?(calls, fn {_, args} -> "/bifrost pin" in args end)
  end

  test "an interactive wrapper that ignores TERM is killed by the same recorded PID", ctx do
    state =
      start_supervised!(
        {Agent, fn -> %{stopped: false, root_stopped: false, pinned: false, calls: []} end}
      )

    base = runner(ctx, state)

    run = fn exe, args, options ->
      if exe == "kill" and args == ["-TERM", "101"], do: {"", 0}, else: base.(exe, args, options)
    end

    assert {:ok, _} =
             SessionModelResume.resume(ctx.row,
               runner: run,
               executables: %{"pi" => ctx.bin},
               key_delay: 0,
               poll_delay: 0
             )

    assert {"kill", ["-KILL", "101"]} in Agent.get(state, & &1.calls)
  end

  test "a failed launch after stopping stays ended with its saved capture and old model", ctx do
    state =
      start_supervised!(
        {Agent, fn -> %{stopped: false, root_stopped: false, pinned: false, calls: []} end}
      )

    base = runner(ctx, state)

    run = fn exe, args, options ->
      if "new-session" in args, do: {"failed", 1}, else: base.(exe, args, options)
    end

    assert {:error, {:model_resume_partial, :stopped, :tmux_unavailable}} =
             SessionModelResume.resume(ctx.row,
               runner: run,
               executables: %{"pi" => ctx.bin},
               poll_delay: 0
             )

    row = AgentSessions.get(ctx.row.id)
    assert row.state == "ended"
    assert row.model == ctx.row.model
    assert SessionCaptures.get(row.id).output == "Usage limit reached"
  end

  test "unconfirmed pin keeps the new pane recorded but sends no continue", ctx do
    state =
      start_supervised!(
        {Agent, fn -> %{stopped: false, root_stopped: false, pinned: false, calls: []} end}
      )

    base = runner(ctx, state)

    run = fn exe, args, options ->
      if "capture-pane" in args and "%42" in args,
        do: {"Bifrost anthropic/claude-opus-5-5", 0},
        else: base.(exe, args, options)
    end

    assert {:error, {:model_resume_partial, :opened, :pin_unconfirmed}} =
             SessionModelResume.resume(ctx.row,
               runner: run,
               executables: %{"pi" => ctx.bin},
               key_delay: 0,
               poll_delay: 0
             )

    row = AgentSessions.get(ctx.row.id)
    assert row.pane_id == "%42"
    assert row.model == "anthropic/claude-opus-5-5"
    assert row.ended_at == nil
    refute Enum.any?(Agent.get(state, & &1.calls), fn {_, args} -> "continue" in args end)
  end

  test "a pinned marker in restored history cannot authorize the first message", ctx do
    state =
      start_supervised!(
        {Agent, fn -> %{stopped: false, root_stopped: false, pinned: false, calls: []} end}
      )

    base = runner(ctx, state)

    run = fn exe, args, options ->
      if "capture-pane" in args and "%42" in args,
        do:
          {"Bifrost · pinned anthropic/claude-opus-5-5\n" <>
             String.duplicate("history\n", 20) <> "Bifrost · unpinned anthropic/claude-opus-5-5\n",
           0},
        else: base.(exe, args, options)
    end

    assert {:error, {:model_resume_partial, :opened, :pin_unconfirmed}} =
             SessionModelResume.resume(ctx.row,
               runner: run,
               executables: %{"pi" => ctx.bin},
               key_delay: 0,
               poll_delay: 0
             )

    refute Enum.any?(Agent.get(state, & &1.calls), fn {_, args} -> "continue" in args end)
  end

  test "a shell left behind by a failed Pi startup receives no keys", ctx do
    state =
      start_supervised!(
        {Agent, fn -> %{stopped: false, root_stopped: false, pinned: false, calls: []} end}
      )

    base = runner(ctx, state)

    run = fn exe, args, options ->
      if "display-message" in args and List.last(args) == "\#{pane_current_command}",
        do: {"zsh\n", 0},
        else: base.(exe, args, options)
    end

    assert {:error, {:model_resume_partial, :opened, :pin_unconfirmed}} =
             SessionModelResume.resume(ctx.row,
               runner: run,
               executables: %{"pi" => ctx.bin},
               key_delay: 0,
               poll_delay: 0
             )

    refute Enum.any?(Agent.get(state, & &1.calls), fn {_, args} -> "send-keys" in args end)
  end

  test "no pair and stale clicks do not signal a process", ctx do
    row = ctx.row |> Ecto.Changeset.change(model: "unpaired") |> Foreman.Repo.update!()
    run = fn _, _, _ -> flunk("must not reach a process") end
    refute AgentSessions.allowed?(row, :resume_on_model)
    assert {:error, :invalid} = SessionModelResume.resume(row, runner: run)
    assert AgentSessions.get(row.id).state == "waiting.usage_limit"
    {:ok, row, _} = AgentSessions.fire(row, :output_changed)
    assert {:error, :invalid} = SessionModelResume.resume(row, runner: run)
  end

  test "failed capture leaves the live process and row unchanged", ctx do
    state =
      start_supervised!(
        {Agent, fn -> %{stopped: false, root_stopped: false, pinned: false, calls: []} end}
      )

    base = runner(ctx, state)

    run = fn exe, args, options ->
      if "capture-pane" in args, do: {"failed", 1}, else: base.(exe, args, options)
    end

    assert {:error, :tmux_unavailable} =
             SessionModelResume.resume(ctx.row, runner: run, executables: %{"pi" => ctx.bin})

    assert AgentSessions.get(ctx.row.id).state == "waiting.usage_limit"
    refute Agent.get(state, & &1.stopped)
  end

  test "a changed PID identity is never signalled", ctx do
    state =
      start_supervised!(
        {Agent, fn -> %{stopped: false, root_stopped: false, pinned: false, calls: []} end}
      )

    base = runner(ctx, state)

    run = fn exe, args, options ->
      result = base.(exe, args, options)
      calls = Agent.get(state, & &1.calls)

      if exe == "ps" and args == ["-p", "102", "-o", "lstart=,stat=,comm="] and
           Enum.count(calls, fn {_, a} -> a == args end) > 1,
         do: {"Fri Nov 6 13:00:00 2026 S pi", 0},
         else: result
    end

    assert {:error, {:model_resume_partial, :stop_unconfirmed, :process_changed}} =
             SessionModelResume.resume(ctx.row, runner: run, executables: %{"pi" => ctx.bin})

    refute Enum.any?(Agent.get(state, & &1.calls), fn {exe, _} -> exe == "kill" end)
  end

  defp runner(ctx, state) do
    fn exe, args, _ ->
      Agent.get_and_update(state, fn s ->
        s = %{s | calls: s.calls ++ [{Path.basename(exe), args}]}

        cond do
          Path.basename(exe) == "ps" and "-axo" in args ->
            {{"101 1 zsh\n102 101 #{ctx.row.harness}\n", 0}, s}

          Path.basename(exe) == "ps" ->
            pid = Enum.at(args, 1)
            gone = if pid == "102", do: s.stopped, else: s.root_stopped

            {if(gone,
               do: {"", 1},
               else: {"Fri Nov 6 12:00:00 2026 S #{if(pid == "102", do: "pi", else: "zsh")}", 0}
             ), s}

          Path.basename(exe) == "kill" ->
            {{"", 0},
             if(List.last(args) == "102",
               do: %{s | stopped: true},
               else: %{s | root_stopped: true}
             )}

          "list-panes" in args and String.contains?(List.last(args), "pane_current_path") ->
            {{"%5\tbuild\t1\t1\t#{if(ctx.row.tmux_server == "board", do: ctx.row.id, else: "")}\t#{ctx.row.workdir}\n",
              0}, s}

          "list-panes" in args ->
            {{"", 0}, s}

          "display-message" in args and List.last(args) == "\#{pane_current_command}" ->
            {{ctx.row.harness, 0}, s}

          "display-message" in args and List.last(args) == "\#{window_id}" ->
            {{"@42\n", 0}, s}

          "display-message" in args ->
            {{"101\n", 0}, s}

          "capture-pane" in args and "%5" in args ->
            {{"Usage limit reached", 0}, s}

          "capture-pane" in args ->
            {{"Bifrost#{if(s.pinned, do: " · pinned", else: "")} anthropic/claude-opus-5-5", 0},
             s}

          "new-session" in args ->
            {{"%42\n", 0}, s}

          "/bifrost pin" in args ->
            {{"", 0}, %{s | pinned: true}}

          true ->
            {{"", 0}, s}
        end
      end)
    end
  end
end
