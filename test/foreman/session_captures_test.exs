defmodule Foreman.SessionCapturesTest do
  @moduledoc "session_captures (spec Decision 15): save and read for exit, last poll, Stop and Park."
  use Foreman.DataCase, async: false
  import ExUnit.CaptureIO
  import Foreman.AgentSessionFixtures
  alias Foreman.{AgentSessions, CLI, PaneCapture, SessionCaptures, TestTmux}

  @t0 ~U[2026-11-05 12:00:00.000000Z]

  describe "save and get" do
    for reason <- [:exit, :poll, :stop, :park] do
      test "#{reason} saves the raw output with its reason and time" do
        row = agent_session()

        assert {:ok, _} =
                 SessionCaptures.save(row.id, "\e[32mok\e[0m\n", unquote(reason), @t0)

        capture = SessionCaptures.get(row.id)
        assert capture.output == "\e[32mok\e[0m\n"
        assert capture.reason == Atom.to_string(unquote(reason))
        assert capture.captured_at == @t0
      end
    end

    test "one row per session: the newest save wins" do
      row = agent_session()
      {:ok, _} = SessionCaptures.save(row.id, "one", :poll, @t0)
      {:ok, _} = SessionCaptures.save(row.id, "two", :poll, DateTime.add(@t0, 5))
      {:ok, _} = SessionCaptures.save(row.id, "three", :stop, DateTime.add(@t0, 9))
      assert %{output: "three", reason: "stop"} = SessionCaptures.get(row.id)
      assert Repo.aggregate(Foreman.SessionCapture, :count) == 1
    end

    for reason <- [:exit, :stop, :park] do
      test "a later poll does not replace the #{reason} save" do
        row = agent_session()
        {:ok, _} = SessionCaptures.save(row.id, "final", unquote(reason), @t0)

        assert SessionCaptures.save(row.id, "later", :poll, DateTime.add(@t0, 2)) ==
                 {:ok, :kept}

        assert %{output: "final"} = SessionCaptures.get(row.id)
      end
    end

    test "an exit save replaces an earlier Stop or poll save" do
      row = agent_session()
      {:ok, _} = SessionCaptures.save(row.id, "stopping", :stop, @t0)
      {:ok, _} = SessionCaptures.save(row.id, "exited", :exit, DateTime.add(@t0, 1))
      assert %{output: "exited", reason: "exit"} = SessionCaptures.get(row.id)
    end

    test "a resumed session drops its old save" do
      row =
        agent_session(harness: "claude", conversation_id: Ecto.UUID.generate())
        |> AgentSessions.end_session()

      {:ok, _} = SessionCaptures.save(row.id, "last run", :exit, @t0)
      {:ok, _, _} = AgentSessions.fire(row, :resume)
      assert SessionCaptures.get(row.id) == nil
    end

    test "bad input is refused" do
      row = agent_session()
      assert SessionCaptures.save(row.id, "x", :later) == {:error, :invalid_reason}
      assert SessionCaptures.save(row.id, <<255>>, :poll) == {:error, :invalid_output}

      assert SessionCaptures.save(row.id, String.duplicate("x", 1_000_001), :poll) ==
               {:error, :too_large}

      assert SessionCaptures.save(Ecto.UUID.generate(), "x", :poll) ==
               {:error, :unknown_session}

      assert SessionCaptures.get("not-a-uuid") == nil
    end
  end

  describe "the Stop and Park save call" do
    test "captures the row's pane on its stored server and saves it" do
      row = agent_session(pane_id: "%7")
      parent = self()

      runner = fn "tmux", args, _ ->
        send(parent, {:tmux, args})
        {"\e[1mlast screen\e[0m\n", 0}
      end

      assert {:ok, _} = SessionCaptures.capture(row, :stop, runner: runner)
      assert_received {:tmux, args}

      assert args ==
               ~w(-N -L default capture-pane -p -e -J -S -200 -t %7)

      assert %{output: "\e[1mlast screen\e[0m\n", reason: "stop"} = SessionCaptures.get(row.id)
    end

    test "bytes that are not UTF-8 are replaced, so the page can show the rest" do
      row = agent_session(pane_id: "%7")

      assert {:ok, _} =
               SessionCaptures.capture(row, :stop,
                 runner: fn _, _, _ -> {<<"ok ", 255, "\n">>, 0} end
               )

      assert %{output: "ok \uFFFD\n"} = SessionCaptures.get(row.id)
    end

    test "a tmux error saves nothing" do
      row = agent_session(pane_id: "%7", kind: "epic_coordinator")

      assert SessionCaptures.capture(row, :park, runner: fn _, _, _ -> {"no server", 1} end) ==
               {:error, :tmux_unavailable}

      assert SessionCaptures.get(row.id) == nil
    end
  end

  describe "tmux on a scratch server" do
    setup do
      socket = TestTmux.socket("so-capture")
      # The pane signals a channel once it has printed, so the test needs no sleep.
      script =
        "printf '\\033[31mred\\033[0m plain\\n'; tmux wait-for -S printed-#{socket}; sleep 30"

      {_, 0} =
        System.cmd(
          "tmux",
          ~w(-L #{socket} -f /dev/null new-session -d -s t -x 80 -y 10) ++ [script]
        )

      {pane, 0} = System.cmd("tmux", ~w(-L #{socket} display-message -p -t t #{"\#{pane_id}"}))
      {_, 0} = System.cmd("tmux", ~w(-L #{socket} wait-for printed-#{socket}))
      %{socket: socket, pane: String.trim(pane)}
    end

    test "read/2 returns the screen with its colour codes", %{socket: socket, pane: pane} do
      assert {:ok, text} =
               PaneCapture.read(%{socket: socket, target: pane}, runner: &System.cmd/3)

      assert text =~ "\e[31mred\e[39m plain"
    end

    test "read/2 reports a missing pane or server as tmux unavailable", %{socket: socket} do
      assert PaneCapture.read(%{socket: socket, target: "%999"}, runner: &System.cmd/3) ==
               {:error, :tmux_unavailable}

      assert PaneCapture.read(%{socket: "so-capture-none", target: "%0"},
               runner: &System.cmd/3
             ) ==
               {:error, :tmux_unavailable}
    end

    test "foreman session capture saves the exit capture of its own pane", %{
      socket: socket,
      pane: pane
    } do
      row = agent_session(name: "exit-build", pane_id: pane)
      {path, 0} = System.cmd("tmux", ~w(-L #{socket} display-message -p #{"\#{socket_path}"}))

      with_env(
        %{
          "TMUX" => String.trim(path) <> ",1,0",
          "TMUX_PANE" => pane,
          "FOREMAN_SESSION" => "exit-build"
        },
        fn -> assert run(~w(session capture)) == "" end
      )

      assert %{reason: "exit", output: output} = SessionCaptures.get(row.id)
      assert output =~ "\e[31mred"
    end
  end

  describe "foreman session capture" do
    test "builds the exit request from the pane it runs in" do
      assert {:ok, %{request: request}} =
               CLI.parse(~w(session capture --name b1),
                 tmux_pane: "%4",
                 tmux: "/private/tmp/tmux-501/default,1,0",
                 capture_pane: fn "%4" -> {:ok, "screen"} end
               )

      assert request == %{
               "action" => "session_capture",
               "session" => "b1",
               "tmux_pane" => "%4",
               "tmux_socket" => "/private/tmp/tmux-501/default",
               "output" => "screen",
               "transient" => true
             }
    end

    test "needs a pane, and says so when tmux cannot read it" do
      with_env(%{"TMUX_PANE" => nil}, fn ->
        assert {:error, "session capture needs --pane <%id> outside tmux"} =
                 CLI.parse(~w(session capture), capture_pane: fn _ -> {:ok, ""} end)
      end)

      assert {:error, "Cannot read pane %4. Nothing was saved."} =
               CLI.parse(~w(session capture --pane %4), capture_pane: fn _ -> :error end)
    end

    test "the board saves it for the asking session, or warns for an unknown one" do
      row = agent_session(name: "cap-build", pane_id: "%31")

      request = %{
        "action" => "session_capture",
        "session" => "cap-build",
        "tmux_pane" => "%31",
        "output" => "bye\n"
      }

      assert {200, %{saved: true}} = Foreman.AgentCommands.execute(request)
      assert %{reason: "exit", output: "bye\n"} = SessionCaptures.get(row.id)
      assert Repo.aggregate("agent_receipts", :count) == 0

      assert {422, %{error: "unknown_session", message: message}} =
               Foreman.AgentCommands.execute(%{
                 request
                 | "session" => "nobody",
                   "tmux_pane" => "%99"
               })

      assert message =~ "The board does not know this session"
    end
  end

  defp with_env(vars, fun) do
    old = Map.new(vars, fn {key, _} -> {key, System.get_env(key)} end)
    Enum.each(vars, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)

    try do
      fun.()
    after
      Enum.each(old, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)
    end
  end

  defp run(args) do
    token = Path.join(System.tmp_dir!(), "cli-token-#{System.unique_integer([:positive])}")
    File.write!(token, "test-only-token-long")
    old = Application.get_env(:foreman, :token_file)
    Application.put_env(:foreman, :token_file, token)
    Req.Test.stub(__MODULE__, fn conn -> ForemanWeb.Endpoint.call(conn, []) end)

    try do
      capture_io(fn ->
        assert CLI.run(args, req_options: [plug: {Req.Test, __MODULE__}]) == 0
      end)
      |> String.trim()
    after
      File.rm(token)

      if old,
        do: Application.put_env(:foreman, :token_file, old),
        else: Application.delete_env(:foreman, :token_file)
    end
  end
end
