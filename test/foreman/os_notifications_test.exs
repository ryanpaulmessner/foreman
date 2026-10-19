defmodule Foreman.OsNotificationsTest do
  use Foreman.DataCase, async: false
  alias Foreman.{OsNotifications, Requests}

  setup do
    Foreman.Overlay.backfill("sample", [%{bead_id: "s-1", status: "open", issue_type: "task"}])
    :ok
  end

  defp ask(question) do
    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "decision", %{"facts" => %{"question" => question}})

    request
  end

  defp start(opts \\ []) do
    test = self()

    runner = fn cmd, args, _opts ->
      send(test, {:ran, cmd, args})
      {"", 0}
    end

    start_supervised!(
      {OsNotifications,
       Keyword.merge(
         [runner: runner, platform: {:unix, :darwin}, subscribe: false, interval: :infinity],
         opts
       )}
    )
  end

  defp changed(pid, id) do
    send(pid, {:notification, :foreman_events, %{"kind" => "requests_changed", "key" => id}})
    _ = :sys.get_state(pid)
  end

  test "posts one native notification per new pending request, never for older ones" do
    _before_boot = ask("Old question?")
    pid = start()
    request = ask("**Ship slice 3?**\n\nDetails follow.")

    changed(pid, request.id)

    assert_receive {:ran, "osascript", args}

    assert args == [
             "-e",
             "on run argv",
             "-e",
             "display notification (item 2 of argv) with title (item 1 of argv)",
             "-e",
             "end run",
             "--",
             "Decision · s-1",
             "Ship slice 3?"
           ]

    changed(pid, request.id)
    send(pid, :tick)
    _ = :sys.get_state(pid)
    refute_receive {:ran, _, _}, 50
  end

  test "the periodic scan catches a request whose event was missed" do
    pid = start()
    _request = ask("Missed?")
    send(pid, :tick)
    _ = :sys.get_state(pid)
    assert_receive {:ran, "osascript", args}
    assert List.last(args) == "Missed?"
  end

  test "agent text is passed as arguments, never spliced into the AppleScript" do
    pid = start()
    request = ask(~s{Evil" & (do shell script "rm -rf ~") & "?\nsecond line})
    changed(pid, request.id)
    assert_receive {:ran, "osascript", args}
    script = args |> Enum.take(6) |> Enum.join(" ")
    refute script =~ "Evil"
    assert List.last(args) == ~s{Evil" & (do shell script "rm -rf ~") & "?}
  end

  test "disabled by config or off macOS posts nothing" do
    pid = start(enabled: false)
    changed(pid, ask("One?").id)
    refute_receive {:ran, _, _}, 50
    stop_supervised!(OsNotifications)

    pid = start(platform: {:unix, :linux})
    changed(pid, ask("Two?").id)
    refute_receive {:ran, _, _}, 50
  end

  test "board.os_notifications in foreman.toml switches it off" do
    {:ok, config} =
      Foreman.Config.parse_layers([
        {"defaults", File.read!("priv/foreman.defaults.toml")},
        {"user", "[board]\nos_notifications = false\n"}
      ])

    assert config["board"]["os_notifications"] == false
    refute OsNotifications.enabled?(%{config: config})
    assert OsNotifications.enabled?(%{config: %{"board" => %{}}})
    assert OsNotifications.enabled?(nil)
  end

  test "titles and bodies name the kind, ticket and first line" do
    request = fn kind, bead, facts ->
      %Foreman.Requests.Request{kind: kind, repo_key: "sample", bead_id: bead, facts: facts}
    end

    assert OsNotifications.message(
             request.("decision", "s-1", %{"question" => "\n# Which?\nmore"})
           ) ==
             {"Decision · s-1", "Which?"}

    assert OsNotifications.message(
             request.("push", "s-1", %{"local_branch" => "feat", "remote_branch" => "main"})
           ) == {"Push · s-1", "feat → main"}

    assert OsNotifications.message(request.("open_pr", "s-1", %{"title" => "Add docs"})) ==
             {"Open PR · s-1", "Add docs"}

    assert OsNotifications.message(request.("merge", "s-1", %{"number" => 7})) ==
             {"Merge · s-1", "PR #7"}

    assert OsNotifications.message(
             request.("session_waiting", "s-1", %{
               "reason" => "question",
               "question" => "Shall I?"
             })
           ) == {"Question · s-1", "Shall I?"}

    assert OsNotifications.message(%{
             request.("session_waiting", "coordinator", %{
               "reason" => "input",
               "questions" => [%{"question" => "Pick one"}]
             })
             | repo_key: "__foreman__"
           }) == {"Question · Coordinator", "Pick one"}

    assert OsNotifications.message(
             request.("session_waiting", "s-1", %{"reason" => "permission", "tool_name" => "Bash"})
           ) == {"Permission needed · s-1", "Bash"}

    {_, body} =
      OsNotifications.message(
        request.("decision", "s-1", %{"question" => String.duplicate("x", 500)})
      )

    assert String.length(body) == 200
  end
end
