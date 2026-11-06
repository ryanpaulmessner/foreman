defmodule Foreman.QueuedNotesTest do
  @moduledoc """
  Notes for a busy coordinator (fm-9mm.23): an R9 answer or a Relaunch build note that
  finds the coordinator mid-turn is saved, and the note monitor types it into that
  coordinator's pane when its prompt next goes idle, at most once. tmux is a stand-in
  whose screen the test switches between busy and idle; it records every call.
  """
  use Foreman.DataCase, async: false
  import Foreman.AgentSessionFixtures
  alias Foreman.{AgentSessions, QueuedNotes, Repo, Requests, SessionResume}

  @busy "✳ Working… (3s)\n───\n❯ \n───\nesc to interrupt\n"
  @idle "───\n❯ \n───\n"

  setup do
    {:ok, screen} = Agent.start_link(fn -> @busy end)
    test = self()

    runner = fn "tmux", args, _ ->
      send(test, {:tmux, args})

      cond do
        "list-panes" in args -> {"%1\t@1\tforeman\tfm-epic\t1\n", 0}
        "capture-pane" in args -> {Agent.get(screen, & &1), 0}
        true -> {"", 0}
      end
    end

    opts = [runner: runner, key_delay: 0]
    Application.put_env(:foreman, :session_controls_tmux, opts)

    on_exit(fn ->
      Application.put_env(:foreman, :session_controls_tmux, runner: &Foreman.TestTmux.no_panes/3)
    end)

    %{screen: screen, opts: opts}
  end

  defp coordinator(attrs \\ %{}),
    do:
      agent_session(
        Map.merge(
          %{name: "fm-epic", kind: "epic_coordinator", harness: "claude", pane_id: "%1"},
          attrs
        )
      )

  defp card(row) do
    %Requests.Request{
      repo_key: "foreman",
      bead_id: "fm-9mm.23",
      kind: "decision",
      actor: "pi",
      state: "pending",
      session: row.name,
      facts: %{"question" => "Keep the line?", "options" => ["Keep it", "Drop it"]}
    }
    |> Repo.insert!()
    |> asked_by(row)
  end

  defp stuck(parent),
    do:
      AgentSessions.end_session(
        agent_session(
          name: "stuck",
          parent_id: parent.id,
          pane_id: "%5",
          ticket: "fm-9mm.23",
          branch: "feat/stuck"
        )
      )

  defp screen(ctx, text), do: Agent.update(ctx.screen, fn _ -> text end)

  # The text typed with `send-keys -l` since the last call, with its pane.
  defp typed do
    receive do
      {:tmux, args} ->
        case args do
          [_, _, _, "send-keys", "-t", pane, "-l", "--", text] -> [{pane, text} | typed()]
          _ -> typed()
        end
    after
      0 -> []
    end
  end

  test "an answer while the coordinator is busy is saved and typed when its prompt next goes idle, once (acceptance 1)",
       ctx do
    parent = coordinator()
    request = card(stuck(parent))

    assert {:ok, %{state: "answered"}} =
             Requests.resolve(request.id, :answer, %{"answer" => "Keep it"})

    assert typed() == []

    assert %{state: "queued", kind: "answer", coordinator_id: coordinator_id} =
             QueuedNotes.for_request(request.id)

    assert coordinator_id == parent.id

    # Still mid-turn: the check types nothing.
    QueuedNotes.run(ctx.opts)
    assert typed() == []
    assert %{state: "queued"} = QueuedNotes.for_request(request.id)

    screen(ctx, @idle)
    QueuedNotes.run(ctx.opts)

    assert typed() == [
             {"%1",
              "[foreman note from board] stuck ended and cannot resume. Ryan answered its card #{request.id}. " <>
                "Question: Keep the line? Answer: Keep it Full outcome: foreman wait #{request.id}"}
           ]

    assert %{state: "sent", done_at: %DateTime{}} = QueuedNotes.for_request(request.id)

    # Never twice.
    QueuedNotes.run(ctx.opts)
    assert typed() == []
  end

  test "a draft in the coordinator's prompt types nothing", ctx do
    parent = coordinator()
    request = card(stuck(parent))
    {:ok, _} = Requests.resolve(request.id, :answer, %{"answer" => "Keep it"})

    screen(ctx, "───\n❯ half a sentence\n───\n")
    QueuedNotes.run(ctx.opts)
    assert typed() == []
    assert %{state: "queued"} = QueuedNotes.for_request(request.id)
  end

  test "a coordinator that ends keeps the note waiting, and another session with its name does not get it",
       ctx do
    parent = coordinator()
    request = card(stuck(parent))
    {:ok, _} = Requests.resolve(request.id, :answer, %{"answer" => "Keep it"})
    AgentSessions.end_session(parent)
    # Start fresh: a new live row with the same name, on an idle prompt.
    _fresh = coordinator()
    screen(ctx, @idle)

    QueuedNotes.run(ctx.opts)
    assert typed() == []
    assert %{state: "queued"} = QueuedNotes.for_request(request.id)
  end

  test "tmux failing after the text went in fails the note, and it is not typed again", ctx do
    parent = coordinator()
    request = card(stuck(parent))
    {:ok, _} = Requests.resolve(request.id, :answer, %{"answer" => "Keep it"})

    # The idle check passes, then every later tmux call fails.
    runner = fn "tmux", args, opts ->
      if "send-keys" in args and "Enter" in args,
        do: {"", 1},
        else: Keyword.fetch!(ctx.opts, :runner).("tmux", args, opts)
    end

    screen(ctx, @idle)
    QueuedNotes.run(Keyword.put(ctx.opts, :runner, runner))
    assert [{"%1", _}] = typed()
    assert %{state: "failed", reason: "typing_failed"} = QueuedNotes.for_request(request.id)

    QueuedNotes.run(ctx.opts)
    assert typed() == []
  end

  test "an attempt the board did not finish fails after the limit and is not typed", ctx do
    parent = coordinator()
    request = card(stuck(parent))
    {:ok, _} = Requests.resolve(request.id, :answer, %{"answer" => "Keep it"})
    note = QueuedNotes.for_request(request.id)
    old = DateTime.add(DateTime.utc_now(), -Foreman.QueuedNote.stale_after() - 5, :second)
    note |> Ecto.Changeset.change(state: "sending", claimed_at: old) |> Repo.update!()

    screen(ctx, @idle)
    QueuedNotes.run(ctx.opts)
    assert typed() == []
    assert %{state: "failed", reason: "lost"} = QueuedNotes.for_request(request.id)
  end

  test "a note you stop is not typed", ctx do
    parent = coordinator()
    request = card(stuck(parent))
    {:ok, _} = Requests.resolve(request.id, :answer, %{"answer" => "Keep it"})
    note = QueuedNotes.for_request(request.id)

    assert {:ok, %{state: "withdrawn"}} = QueuedNotes.withdraw(note.id)
    assert {:error, :invalid} = QueuedNotes.withdraw(note.id)

    screen(ctx, @idle)
    QueuedNotes.run(ctx.opts)
    assert typed() == []
  end

  test "Relaunch build while the coordinator is busy saves one note and types it when idle",
       ctx do
    parent = coordinator()
    build = stuck(parent)

    assert {:ok, %{coordinator: "fm-epic", queued: true}} =
             SessionResume.relaunch_build(build, ctx.opts)

    # Pressed again while it waits: no second note, nothing typed now even on an idle prompt.
    screen(ctx, @idle)

    assert {:ok, %{queued: true}} = SessionResume.relaunch_build(build, ctx.opts)
    assert typed() == []
    assert [%{state: "queued", kind: "relaunch"}] = QueuedNotes.for_subject(build.id)

    QueuedNotes.run(ctx.opts)

    assert typed() == [
             {"%1", "[foreman note from board] Relaunch the build for fm-9mm.23 on feat/stuck."}
           ]

    assert [%{state: "sent"}] = QueuedNotes.for_subject(build.id)
  end

  test "two notes for one coordinator go one per check", ctx do
    parent = coordinator()
    first = card(stuck(parent))
    second_build = AgentSessions.end_session(agent_session(name: "stuck-2", parent_id: parent.id))
    second = card(second_build)
    {:ok, _} = Requests.resolve(first.id, :answer, %{"answer" => "Keep it"})
    {:ok, _} = Requests.resolve(second.id, :answer, %{"answer" => "Drop it"})

    screen(ctx, @idle)
    QueuedNotes.run(ctx.opts)
    assert [{"%1", text}] = typed()
    assert text =~ first.id
    assert %{state: "queued"} = QueuedNotes.for_request(second.id)
  end

  test "the worker timer runs a check on each tick", ctx do
    parent = coordinator()
    request = card(stuck(parent))
    {:ok, _} = Requests.resolve(request.id, :answer, %{"answer" => "Keep it"})
    screen(ctx, @idle)

    pid = start_supervised!({Foreman.QueuedNoteMonitor, interval: :timer.hours(1)})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    send(pid, :tick)
    _ = :sys.get_state(pid)
    assert [{"%1", _}] = typed()
    assert %{state: "sent"} = QueuedNotes.for_request(request.id)
  end

  test "the preview never types a note", ctx do
    parent = coordinator()
    request = card(stuck(parent))
    {:ok, _} = Requests.resolve(request.id, :answer, %{"answer" => "Keep it"})
    screen(ctx, @idle)
    System.put_env("PREVIEW", "1")
    on_exit(fn -> System.delete_env("PREVIEW") end)

    assert {:error, _} = QueuedNotes.run(ctx.opts)
    assert typed() == []
    assert %{state: "queued"} = QueuedNotes.for_request(request.id)
  end

  describe "board events (review r1)" do
    setup ctx do
      test = self()
      notify = fn kind, key -> send(test, {:broadcast, kind, key}) && :ok end
      %{opts: Keyword.put(ctx.opts, :notify, notify)}
    end

    defp broadcasts do
      receive do
        {:broadcast, kind, key} -> [{kind, key} | broadcasts()]
      after
        0 -> []
      end
    end

    test "a check against a busy coordinator broadcasts nothing, writes nothing and leaves the note queued",
         ctx do
      parent = coordinator()
      request = card(stuck(parent))
      {:ok, _} = Requests.resolve(request.id, :answer, %{"answer" => "Keep it"})
      before = QueuedNotes.for_request(request.id)

      for _ <- 1..3, do: QueuedNotes.run(ctx.opts)

      assert broadcasts() == []
      assert typed() == []
      after_checks = QueuedNotes.for_request(request.id)
      assert %{state: "queued", claimed_at: nil} = after_checks
      assert after_checks.updated_at == before.updated_at
    end

    test "a prompt that turns busy after the claim releases the note without a broadcast", ctx do
      parent = coordinator()
      request = card(stuck(parent))
      {:ok, _} = Requests.resolve(request.id, :answer, %{"answer" => "Keep it"})

      # Idle for the read-only check, busy for the check right before typing.
      {:ok, captures} = Agent.start_link(fn -> [@idle, @busy] end)

      runner = fn "tmux", args, opts ->
        if "capture-pane" in args do
          {Agent.get_and_update(captures, fn [h | t] -> {h, t ++ [h]} end), 0}
        else
          Keyword.fetch!(ctx.opts, :runner).("tmux", args, opts)
        end
      end

      QueuedNotes.run(Keyword.put(ctx.opts, :runner, runner))
      assert typed() == []
      assert broadcasts() == []
      assert %{state: "queued", claimed_at: nil} = QueuedNotes.for_request(request.id)
    end

    test "sending broadcasts once, for the card", ctx do
      parent = coordinator()
      request = card(stuck(parent))
      {:ok, _} = Requests.resolve(request.id, :answer, %{"answer" => "Keep it"})
      screen(ctx, @idle)

      QueuedNotes.run(ctx.opts)
      assert [{"%1", _}] = typed()
      assert broadcasts() == [{:requests_changed, request.id}]
      assert %{state: "sent"} = QueuedNotes.for_request(request.id)
    end
  end
end
