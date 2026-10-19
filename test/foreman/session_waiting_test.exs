defmodule Foreman.SessionWaitingTest do
  use Foreman.DataCase, async: false
  alias Foreman.{Requests, Repo, Sessions}

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
