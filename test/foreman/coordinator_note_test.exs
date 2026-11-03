defmodule Foreman.CoordinatorNoteTest do
  use Foreman.DataCase, async: false
  import Ecto.Query

  test "note CLI is a transient coordinator command, not a local ticket note" do
    args = ["note", "--all-coordinators", "Use a test partition", "--json"]
    refute Foreman.TicketCLI.command?(args)
    assert {:ok, %{request: r}} = Foreman.CLI.parse(args, actor: "claude", session: "coord")
    assert r["action"] == "coordinator_note"
    assert r["text"] == "Use a test partition"
    assert r["transient"] == true
    assert r["actor"] == "claude"
    assert Foreman.TicketCLI.command?(["note", "s-1", "A ticket note"])
  end

  test "server refuses non-coordinators and invalid text before any delivery" do
    for actor <- ["pi", "user", nil] do
      assert {422, %{error: "coordinator_only"}} =
               Foreman.AgentCommands.execute(%{
                 "action" => "coordinator_note",
                 "actor" => actor,
                 "session" => "coord",
                 "text" => "Note"
               })
    end

    for text <- [nil, "", String.duplicate("a", 2000), "bad\0text"] do
      assert {422, %{error: "invalid_note"}} =
               Foreman.AgentCommands.execute(%{
                 "action" => "coordinator_note",
                 "actor" => "claude",
                 "session" => "coord",
                 "text" => text
               })
    end
  end

  @tag :tmp_dir
  test "command delivers through an isolated tmux server and a receipt prevents replay", %{
    tmp_dir: dir
  } do
    socket = Foreman.TestTmux.socket("fm-note")
    old = Application.get_env(:foreman, :external_tmux_socket)
    Application.put_env(:foreman, :external_tmux_socket, socket)

    on_exit(fn ->
      if old,
        do: Application.put_env(:foreman, :external_tmux_socket, old),
        else: Application.delete_env(:foreman, :external_tmux_socket)
    end)

    script = Path.join(dir, "prompt.sh")
    output = Path.join(dir, "received")

    File.write!(
      script,
      "printf '───\\n❯\\n───\\n'\ntmux -L #{socket} wait-for -S ready\nIFS= read -r line\nprintf '%s' \"$line\" > '#{output}'\ntmux -L #{socket} wait-for -S received\nread rest\n"
    )

    {pane, 0} =
      System.cmd(
        "tmux",
        [
          "-L",
          socket,
          "-f",
          "/dev/null",
          "new-session",
          "-d",
          "-P",
          "-F",
          "\#{pane_id}",
          "sh #{script}"
        ],
        env: [{"SHELL", "/bin/sh"}]
      )

    {_, 0} = System.cmd("tmux", ["-L", socket, "wait-for", "ready"])

    {:ok, _} =
      Foreman.SessionRegistry.register(%{
        "name" => "coord",
        "pane" => String.trim(pane),
        "workdir" => dir,
        "harness" => "claude"
      })

    command = %{
      "action" => "coordinator_note",
      "actor" => "claude",
      "session" => "source",
      "text" => "Use MIX_TEST_PARTITION",
      "request_id" => Ecto.UUID.generate()
    }

    assert {200, %{delivered: [%{name: "coord"}], skipped: []}} =
             Foreman.AgentCommands.execute(command)

    {_, 0} = System.cmd("tmux", ["-L", socket, "wait-for", "received"])
    assert File.read!(output) == "[foreman note from source] Use MIX_TEST_PARTITION"

    assert {200, %{"delivered" => [%{"name" => "coord"}], "skipped" => []}} =
             Foreman.AgentCommands.execute(command)
  end

  test "Pi coordinators receive notes only at an empty idle editor" do
    for n <- 1..6 do
      {:ok, _} =
        Foreman.SessionRegistry.register(%{
          "name" => "pi-#{n}",
          "pane" => "%#{n}",
          "workdir" => "/tmp",
          "harness" => "pi"
        })
    end

    parent = self()

    runner = fn "tmux", args, _ ->
      case Enum.drop(args, 3) do
        ["list-panes" | _] ->
          {Enum.map_join(1..6, "\n", &"%#{&1}\t@#{&1}\tsession\tcoord\t1"), 0}

        ["display-message" | _] ->
          {"node\tpi --name coord", 0}

        ["capture-pane", "-p", "-J", "-t", "%5"] ->
          {"── ⠋ Working ─────\n\n────────\nfooter", 0}

        ["capture-pane", "-p", "-J", "-t", "%6"] ->
          {"────────\ndraft\n────────\nfooter", 0}

        ["capture-pane" | _] ->
          {"────────\n\n────────\nfooter", 0}

        ["send-keys", "-t", pane, "-l", "--", text] ->
          send(parent, {:typed, pane, text})
          {"", 0}

        ["send-keys", "-t", pane, "Enter"] ->
          send(parent, {:enter, pane})
          {"", 0}
      end
    end

    assert {:ok, result} =
             Foreman.CoordinatorNote.send("claude", "source", "Note",
               runner: runner,
               key_delay: 0
             )

    assert Enum.map(result.delivered, & &1.name) == ~w(pi-1 pi-2 pi-3 pi-4)

    assert Enum.map(result.skipped, &{&1.name, &1.reason}) == [
             {"pi-5", "prompt_busy"},
             {"pi-6", "prompt_busy"}
           ]

    for n <- 1..4 do
      pane = "%#{n}"
      assert_receive {:typed, ^pane, "[foreman note from source] Note"}
      assert_receive {:enter, ^pane}
    end

    refute_receive {:typed, _, _}
  end

  test "broadcast reaches idle coordinators once and reports busy, ended and missing panes" do
    for {name, pane} <- [
          {"idle", "%1"},
          {"busy", "%2"},
          {"ended", "%3"},
          {"gone", "%4"},
          {"alias", "%1"}
        ] do
      {:ok, _} =
        Foreman.SessionRegistry.register(%{
          "name" => name,
          "pane" => pane,
          "workdir" => "/tmp",
          "harness" => "claude"
        })
    end

    Repo.update_all(from(s in "sessions", where: s.window == "%3"),
      set: [ended_at: DateTime.utc_now()]
    )

    parent = self()

    runner = fn "tmux", args, _ ->
      case Enum.drop(args, 3) do
        ["list-panes" | _] ->
          {"%1\t@1\tsession\tidle\t1\n%2\t@2\tsession\tbusy\t1\n%3\t@3\tsession\tended\t1\n", 0}

        ["capture-pane", "-p", "-J", "-t", "%1"] ->
          {"───\n❯\n───", 0}

        ["capture-pane", "-p", "-J", "-t", "%2"] ->
          {"───\n❯\n───\nesc to interrupt", 0}

        ["send-keys", "-t", pane, "-l", "--", text] ->
          send(parent, {:typed, pane, text})
          {"", 0}

        ["send-keys", "-t", pane, "Enter"] ->
          send(parent, {:enter, pane})
          {"", 0}
      end
    end

    assert {:ok, result} =
             Foreman.CoordinatorNote.send("claude", "source", "Use a test partition",
               runner: runner,
               key_delay: 0
             )

    assert length(result.delivered) == 1

    assert Enum.sort(Enum.map(result.skipped, & &1.reason)) ==
             ~w(already_delivered prompt_busy session_ended window_gone)

    assert_receive {:typed, "%1", "[foreman note from source] Use a test partition"}
    assert_receive {:enter, "%1"}
    refute_receive {:typed, _, _}
    refute_receive {:enter, _}
  end

  test "a board note reaches only the named coordinator, or says why it cannot" do
    for {name, pane} <- [{"owner", "%1"}, {"other", "%2"}, {"gone", "%3"}] do
      {:ok, _} =
        Foreman.SessionRegistry.register(%{
          "name" => name,
          "pane" => pane,
          "workdir" => "/tmp",
          "harness" => "claude"
        })
    end

    Repo.update_all(from(s in "sessions", where: s.window == "%3"),
      set: [ended_at: DateTime.utc_now()]
    )

    parent = self()

    runner = fn "tmux", args, _ ->
      case Enum.drop(args, 3) do
        ["list-panes" | _] ->
          {"%1\t@1\tsession\towner\t1\n%2\t@2\tsession\tother\t1\n", 0}

        ["capture-pane", "-p", "-J", "-t", _] ->
          {"───\n❯\n───", 0}

        ["send-keys", "-t", pane, "-l", "--", text] ->
          send(parent, {:typed, pane, text}) && {"", 0}

        ["send-keys", "-t", _, "Enter"] ->
          {"", 0}
      end
    end

    assert :ok =
             Foreman.CoordinatorNote.send_to("owner", "Review s-1", runner: runner, key_delay: 0)

    assert_receive {:typed, "%1", "[foreman note from board] Review s-1"}
    refute_receive {:typed, _, _}

    assert {:error, :session_ended} =
             Foreman.CoordinatorNote.send_to("gone", "x", runner: runner, key_delay: 0)

    assert {:error, :not_registered} =
             Foreman.CoordinatorNote.send_to("nobody", "x", runner: runner, key_delay: 0)
  end
end
