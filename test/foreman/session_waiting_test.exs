defmodule Foreman.SessionWaitingTest do
  use Foreman.DataCase, async: false
  alias Foreman.{Requests, Repo, Sessions, ScratchPrompt}

  setup do
    Foreman.Overlay.backfill("sample", [%{bead_id: "s-1", status: "open", issue_type: "task"}])

    session =
      Repo.insert!(%Foreman.PlanningSession{
        project: "sample",
        ticket: "s-1",
        workdir: "/tmp",
        window: "@42",
        state: :running,
        launched_at: DateTime.utc_now()
      })

    %{session: session}
  end

  test "a repeated waiting hook is still activity", %{session: s} do
    params = %{"session" => s.session_id, "facts" => %{"reason" => "input", "tool" => "ask"}}
    {:ok, request} = Requests.ask({"sample", "s-1"}, "session_waiting", params)
    old = DateTime.add(DateTime.utc_now(), -90_000, :second)

    Sessions.get({"sample", "s-1"})
    |> Ecto.Changeset.change(last_activity_at: old)
    |> Repo.update!()

    assert {:ok, repeated} = Requests.ask({"sample", "s-1"}, "session_waiting", params)
    assert repeated.id == request.id

    assert {200, %{state: :waiting}} =
             Foreman.AgentCommands.execute(%{
               "action" => "session_activity",
               "repo" => "sample",
               "id" => "s-1",
               "session" => s.session_id
             })

    assert Requests.get(request.id).state == "pending"
    assert DateTime.compare(Sessions.get({"sample", "s-1"}).last_activity_at, old) == :gt
  end

  test "question and tool-name facts are kept; malformed ones are dropped, not refused", %{
    session: s
  } do
    questions = [%{"question" => "Which?", "options" => ["A", "B"], "multi" => false}]

    {:ok, question} =
      Requests.ask({"sample", "s-1"}, "session_waiting", %{
        "session" => s.session_id,
        "facts" => %{
          "reason" => "input",
          "tool" => "q-1",
          "tool_name" => "AskUserQuestion",
          "questions" => questions
        }
      })

    assert question.facts["questions"] == questions
    assert question.facts["tool_name"] == "AskUserQuestion"

    {:ok, permission} =
      Requests.ask({"sample", "s-1"}, "session_waiting", %{
        "session" => s.session_id,
        "facts" => %{
          "reason" => "permission",
          "tool" => "p-1",
          "tool_name" => "Bash rm -rf /",
          "title" => "Spoofed by a hook",
          "questions" => [%{"question" => "x", "options" => [%{}], "multi" => "no"}]
        }
      })

    refute Map.has_key?(permission.facts, "tool_name")
    refute Map.has_key?(permission.facts, "questions")
    refute Map.has_key?(permission.facts, "title")
  end

  test "a planning session's idle Stop waits without asking", %{session: s} do
    {:waiting, facts} = Foreman.SessionHooks.facts("Stop", %{})

    assert {200, %{state: :waiting}} =
             Foreman.AgentCommands.execute(%{
               "action" => "ask",
               "request_kind" => "session_waiting",
               "repo" => "sample",
               "id" => "s-1",
               "session" => s.session_id,
               "facts" => facts
             })

    assert Requests.pending() == []
    assert Sessions.get({"sample", "s-1"}).state == :waiting
  end

  test "a chat question without usable text is an ordinary idle Stop", %{session: s} do
    for question <- [nil, "", "  ", 7, String.duplicate("x", 8_001)] do
      facts = %{"reason" => "question", "question" => question}

      assert {:ok, %Foreman.PlanningSession{state: :waiting}} =
               Requests.ask({"sample", "s-1"}, "session_waiting", %{
                 "session" => s.session_id,
                 "facts" => facts
               })
    end

    assert Requests.pending() == []

    # Question text never rides along on another reason.
    {:ok, permission} =
      Requests.ask({"sample", "s-1"}, "session_waiting", %{
        "session" => s.session_id,
        "facts" => %{"reason" => "permission", "tool" => "p-1", "question" => "Shall I?"}
      })

    refute Map.has_key?(permission.facts, "question")
  end

  test "an external pi session waiting for input still asks" do
    Foreman.Overlay.backfill("sample", [%{bead_id: "s-2", status: "open", issue_type: "task"}])
    socket = "fm-external-#{System.unique_integer([:positive])}"

    {_, 0} =
      System.cmd("tmux", [
        "-L",
        socket,
        "-f",
        "/dev/null",
        "new-session",
        "-d",
        "-s",
        "sample",
        "-n",
        "build",
        "sleep 60"
      ])

    old = Application.get_env(:foreman, :external_tmux_socket)
    Application.put_env(:foreman, :external_tmux_socket, socket)

    on_exit(fn ->
      if old,
        do: Application.put_env(:foreman, :external_tmux_socket, old),
        else: Application.delete_env(:foreman, :external_tmux_socket)

      System.cmd("tmux", ["-L", socket, "kill-server"], stderr_to_stdout: true)
    end)

    assert {:ok, request} =
             Requests.ask({"sample", "s-2"}, "session_waiting", %{
               "session" => "pi-build",
               "facts" => %{"reason" => "input", "window" => "build"}
             })

    assert request.facts["target"] == "external"
    assert [%{id: id}] = Requests.pending()
    assert id == request.id
  end

  test "completion of an unrelated parallel tool does not clear a permission wait", %{session: s} do
    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "session_waiting", %{
        "session" => s.session_id,
        "facts" => %{"reason" => "permission", "tool" => "bash-probe"}
      })

    envelope = %{
      "action" => "session_resumed",
      "repo" => "sample",
      "id" => "s-1",
      "session" => s.session_id,
      "resume_tool" => "read-probe"
    }

    assert {200, _} = Foreman.AgentCommands.execute(envelope)
    assert Requests.get(request.id).state == "pending"
    assert {:ok, _} = Sessions.signal({"sample", "s-1"}, s.session_id, :resumed, "activity")
    assert Requests.get(request.id).state == "pending"

    assert {200, _} =
             Foreman.AgentCommands.execute(Map.put(envelope, "resume_tool", "bash-probe"))

    assert Requests.get(request.id).state == "superseded"
  end

  test "tool-start activity clears a provider stop without clearing a tool-specific wait", %{
    session: s
  } do
    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "session_waiting", %{
        "session" => s.session_id,
        "facts" => %{"reason" => "usage_limit"}
      })

    assert {:ok, _} = Sessions.signal({"sample", "s-1"}, s.session_id, :resumed, "activity")
    assert Requests.get(request.id).state == "superseded"
  end

  test "invalid reason, absent session and invalid display facts are refused", %{session: s} do
    for params <- [
          %{"facts" => %{"reason" => "input"}},
          %{"session" => s.session_id, "facts" => %{"reason" => "other"}},
          %{"session" => s.session_id, "facts" => %{"reason" => "usage_limit", "provider" => %{}}}
        ] do
      assert {:error, _} = Requests.ask({"sample", "s-1"}, "session_waiting", params)
    end

    assert Requests.pending() == []
  end

  test "Continue is click-only, refuses other reasons and stale requests, and clears on activity",
       %{session: s} do
    socket = "fm-waiting-#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), socket)
    File.mkdir_p!(dir)
    executable = Path.join(dir, "receiver")

    File.write!(
      executable,
      "#!/bin/sh\nstty -echo\nprintf ready > ready\nwhile IFS= read -r line; do printf '%s\\n' \"$line\" >> received; done\n"
    )

    File.chmod!(executable, 0o700)

    {_, 0} =
      System.cmd("tmux", [
        "-L",
        socket,
        "-f",
        "/dev/null",
        "start-server",
        ";",
        "set-option",
        "-g",
        "exit-empty",
        "off"
      ])

    old = Application.get_env(:foreman, :planning_tmux_socket)
    Application.put_env(:foreman, :planning_tmux_socket, socket)

    on_exit(fn ->
      if old,
        do: Application.put_env(:foreman, :planning_tmux_socket, old),
        else: Application.delete_env(:foreman, :planning_tmux_socket)

      System.cmd("tmux", ["-L", socket, "kill-server"], stderr_to_stdout: true)
      File.rm_rf!(dir)
    end)

    s = s |> Ecto.Changeset.change(workdir: dir) |> Repo.update!()
    {:ok, window} = Foreman.SessionTmux.launch(s, "flow", executable: executable)
    s |> Ecto.Changeset.change(window: window) |> Repo.update!()
    assert eventually(fn -> File.exists?(Path.join(dir, "ready")) end)

    {:ok, permission} =
      Requests.ask({"sample", "s-1"}, "session_waiting", %{
        "session" => s.session_id,
        "facts" => %{"reason" => "permission"}
      })

    assert {:error, :invalid} = Foreman.SessionWaiting.continue(permission.id)

    {:ok, limited} =
      Requests.ask({"sample", "s-1"}, "session_waiting", %{
        "session" => s.session_id,
        "facts" => %{"reason" => "usage_limit"}
      })

    refute File.exists?(Path.join(dir, "received"))
    assert {:ok, _} = Foreman.SessionWaiting.continue(limited.id)
    assert eventually(fn -> File.exists?(Path.join(dir, "received")) end)
    assert File.read!(Path.join(dir, "received")) == "continue\n"
    assert {:ok, _} = Sessions.signal({"sample", "s-1"}, s.session_id, :resumed)
    assert {:error, :invalid} = Foreman.SessionWaiting.continue(limited.id)
    assert File.read!(Path.join(dir, "received")) == "continue\n"
  end

  test "Open session switches the latest client to the pane, then brings the terminal forward",
       %{session: s} do
    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "session_waiting", %{
        "session" => s.session_id,
        "facts" => %{"reason" => "permission", "tool" => "p-1", "tool_name" => "Bash"}
      })

    clients = "1700000000\t/dev/ttys003\n1700000100\t/dev/ttys009\n"
    test = self()

    runner = fn
      "tmux", args, _ ->
        send(test, {:cmd, "tmux", args})

        cond do
          "list-windows" in args ->
            {"sample\ts-1\t@42\trunning\t0\t#{s.session_id}\n", 0}

          "display-message" in args ->
            {"#{s.session_id} %7\n", 0}

          "list-clients" in args ->
            {Process.get(:clients, clients), 0}

          true ->
            {"", 0}
        end

      exe, args, _ ->
        send(test, {:cmd, exe, args})
        {"", 0}
    end

    assert :ok =
             Foreman.SessionWaiting.open(request.id, runner: runner, platform: {:unix, :darwin})

    calls = drain()

    assert ["switch-client", "-c", "/dev/ttys009", "-t", "%7"] in Enum.map(
             calls,
             &Enum.take(elem(&1, 1), -5)
           )

    assert {"osascript", ["-e", ~s(tell application "Ghostty" to activate)]} in calls
    assert Requests.get(request.id).state == "pending"

    assert :ok =
             Foreman.SessionWaiting.open(request.id,
               runner: runner,
               platform: {:unix, :linux},
               app: "WezTerm"
             )

    refute Enum.any?(drain(), &(elem(&1, 0) == "osascript"))

    Process.put(:clients, "")

    assert {:error, :no_client} =
             Foreman.SessionWaiting.open(request.id, runner: runner, platform: {:unix, :darwin})

    calls = drain()
    refute Enum.any?(calls, &(elem(&1, 0) == "osascript"))
    refute Enum.any?(calls, &("switch-client" in elem(&1, 1)))
  end

  defp drain(calls \\ []) do
    receive do
      {:cmd, exe, args} -> drain([{exe, args} | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end

  test "an inline answer types into the question pane once, and a changed pane refuses",
       %{session: s} do
    {s, received} = ScratchPrompt.start(s)

    ask = fn tool ->
      Requests.ask({"sample", "s-1"}, "session_waiting", %{
        "session" => s.session_id,
        "facts" => %{
          "reason" => "input",
          "tool" => tool,
          "tool_name" => "AskUserQuestion",
          "questions" => [ScratchPrompt.question()]
        }
      })
    end

    {:ok, request} = ask.("q-1")

    assert {:ok, answered} =
             Foreman.SessionWaiting.reply(request.id, {:option, 1}, key_delay: 20)

    assert answered.state == "answered"
    assert answered.outcome == %{"reason" => "answered_in_foreman"}
    assert eventually(fn -> ScratchPrompt.received(received) == "2" end)

    # The pane moved on: a new request for the same question must not type.
    {:ok, stale} = ask.("q-2")

    assert {:error, :prompt_changed} =
             Foreman.SessionWaiting.reply(stale.id, {:option, 0}, key_delay: 20)

    assert Requests.get(stale.id).state == "pending"
    assert ScratchPrompt.received(received) == "2"
    assert {:error, :invalid} = Foreman.SessionWaiting.reply(request.id, {:option, 0})
  end

  test "an Other answer focuses the free-text row, types the text, then sends Enter",
       %{session: s} do
    {s, received} = ScratchPrompt.start(s)

    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "session_waiting", %{
        "session" => s.session_id,
        "facts" => %{
          "reason" => "input",
          "tool" => "q-1",
          "questions" => [ScratchPrompt.question()]
        }
      })

    assert {:ok, _} =
             Foreman.SessionWaiting.reply(request.id, {:other, "both, 2 of each"}, key_delay: 20)

    assert eventually(fn -> ScratchPrompt.received(received) == "3both, 2 of each\r" end)
  end

  defp chat_question(s) do
    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "session_waiting", %{
        "session" => s.session_id,
        "facts" => %{"reason" => "question", "question" => "Shall I commit it?"}
      })

    request
  end

  test "a chat reply types into an idle prompt, then Enter, and answers the request",
       %{session: s} do
    {s, received} = ScratchPrompt.start_chat(s, :idle)
    request = chat_question(s)

    assert {:ok, answered} =
             Foreman.SessionWaiting.reply(request.id, {:text, "yes, commit it"}, key_delay: 20)

    assert answered.state == "answered"
    assert answered.outcome == %{"reason" => "answered_in_foreman"}
    assert eventually(fn -> ScratchPrompt.received(received) == "yes, commit it\r" end)

    # Answered once: a second click types nothing.
    assert {:error, :invalid} = Foreman.SessionWaiting.reply(request.id, {:text, "again"})
    assert ScratchPrompt.received(received) == "yes, commit it\r"
  end

  test "a chat reply refuses a busy pane and types nothing", %{session: s} do
    {s, received} = ScratchPrompt.start_chat(s, :busy)
    request = chat_question(s)

    assert {:error, :prompt_busy} =
             Foreman.SessionWaiting.reply(request.id, {:text, "yes"}, key_delay: 20)

    assert Requests.get(request.id).state == "pending"
    assert ScratchPrompt.received(received) == ""

    assert {:error, :answer_required} =
             Foreman.SessionWaiting.reply(request.id, {:text, "  "}, key_delay: 20)

    assert {:error, :invalid} = Foreman.SessionWaiting.reply(request.id, {:option, 0})
  end

  test "a chat reply sends the text and Enter as two separate send-keys calls", %{session: s} do
    request = chat_question(s)
    test = self()
    rule = String.duplicate("─", 20)

    runner = fn "tmux", args, _ ->
      send(test, {:cmd, "tmux", args})

      cond do
        "list-windows" in args -> {"sample\ts-1\t@42\trunning\t0\t#{s.session_id}\n", 0}
        "display-message" in args -> {"#{s.session_id} %7\n", 0}
        "capture-pane" in args -> {"✻ Worked for 2s\n#{rule}\n❯ \n#{rule}\n  footer\n", 0}
        true -> {"", 0}
      end
    end

    assert {:ok, _} =
             Foreman.SessionWaiting.reply(request.id, {:text, "ship\nit"},
               runner: runner,
               key_delay: 0
             )

    sends =
      for {_, args} <- drain(),
          "send-keys" in args,
          do: Enum.drop_while(args, &(&1 != "send-keys"))

    assert sends == [
             ["send-keys", "-t", "%7", "-l", "--", "ship it"],
             ["send-keys", "-t", "%7", "Enter"]
           ]
  end

  test "a chat reply to an external session needs the same pane and process", %{session: _} do
    Foreman.Overlay.backfill("sample", [%{bead_id: "s-2", status: "open", issue_type: "task"}])
    socket = "fm-external-#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), socket)
    File.mkdir_p!(dir)
    executable = Path.join(dir, "prompt")
    File.write!(executable, ScratchPrompt.chat_script(:idle))
    File.chmod!(executable, 0o700)

    {_, 0} =
      System.cmd(
        "tmux",
        ["-L", socket, "-f", "/dev/null", "new-session", "-d", "-s", "sample"] ++
          ["-n", "build", "-c", dir, executable]
      )

    old = Application.get_env(:foreman, :external_tmux_socket)
    Application.put_env(:foreman, :external_tmux_socket, socket)

    on_exit(fn ->
      if old,
        do: Application.put_env(:foreman, :external_tmux_socket, old),
        else: Application.delete_env(:foreman, :external_tmux_socket)

      System.cmd("tmux", ["-L", socket, "kill-server"], stderr_to_stdout: true)
      File.rm_rf!(dir)
    end)

    assert eventually(fn -> File.exists?(Path.join(dir, "ready")) end)

    ask = fn ->
      Requests.ask({"sample", "s-2"}, "session_waiting", %{
        "session" => "pi-build",
        "facts" => %{"reason" => "question", "question" => "Push now?", "window" => "build"}
      })
    end

    {:ok, request} = ask.()
    assert request.facts["target"] == "external"

    # Same window name, different process: refused.
    stale = %{request | facts: %{request.facts | "pid" => "1"}}

    assert {:error, :window_gone} =
             Foreman.SessionTmux.reply_external(stale.facts, "yes", key_delay: 20)

    assert ScratchPrompt.received(Path.join(dir, "received")) == ""

    assert {:ok, _} = Foreman.SessionWaiting.reply(request.id, {:text, "yes"}, key_delay: 20)

    assert eventually(fn ->
             ScratchPrompt.received(Path.join(dir, "received")) == "yes\r"
           end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_, 0), do: false

  defp eventually(fun, n) do
    if fun.(),
      do: true,
      else:
        (receive do
         after
           20 -> eventually(fun, n - 1)
         end)
  end

  test "waiting is deduplicated, non-executable and cleared by resumed activity", %{session: s} do
    params = %{"session" => s.session_id, "facts" => %{"reason" => "permission"}}
    assert {:ok, request} = Requests.ask({"sample", "s-1"}, "session_waiting", params)
    assert request.facts["attach"] =~ "tmux -L"
    assert {:ok, again} = Requests.ask({"sample", "s-1"}, "session_waiting", params)
    assert again.id == request.id
    assert Sessions.get({"sample", "s-1"}).state == :waiting
    assert {:error, :invalid} = Requests.resolve(request.id, :approve, %{})
    assert {:error, :invalid} = Requests.resolve(request.id, :answer, %{"answer" => "yes"})
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert {:ok, resumed} = Sessions.signal({"sample", "s-1"}, s.session_id, :resumed)
    assert resumed.state == :running
    assert Requests.get(request.id).state == "superseded"
    assert Requests.pending() == []
  end
end
