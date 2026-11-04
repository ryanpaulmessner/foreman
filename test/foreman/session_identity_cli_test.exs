defmodule Foreman.SessionIdentityCLITest do
  # CLI wire format for session identity: ask, dispatch --name --pi-session, session register --parent.
  use Foreman.DataCase, async: false
  import ExUnit.CaptureIO
  alias Foreman.{AgentSessions, CLI}

  @facts ~w(--question Ship? --text) ++
           ["What: x\nPart of: one-off\nWhy now: y"] ++
           ~w(--option A --option-detail A=a --option B --option-detail B=b)

  setup do
    token = Path.join(System.tmp_dir!(), "cli-token-#{System.unique_integer([:positive])}")
    File.write!(token, "test-only-token-long")
    old_token = Application.get_env(:foreman, :token_file)
    Application.put_env(:foreman, :token_file, token)
    env = Map.new(~w(TMUX TMUX_PANE FOREMAN_SESSION FOREMAN_ACTOR), &{&1, System.get_env(&1)})

    on_exit(fn ->
      File.rm(token)

      if old_token,
        do: Application.put_env(:foreman, :token_file, old_token),
        else: Application.delete_env(:foreman, :token_file)

      for {key, value} <- env,
          do: if(value, do: System.put_env(key, value), else: System.delete_env(key))
    end)

    {:ok, config} =
      Foreman.Config.parse_layers([{"defaults", File.read!("priv/foreman.defaults.toml")}])

    config =
      Map.put(config, "repos", [%{"key" => "sample", "path" => "/tmp/sample", "enabled" => true}])

    Repo.insert_all("board_config", [
      %{id: 1, config: config, source: "test", discovered: [], loaded_at: DateTime.utc_now()}
    ])

    Foreman.Beads.Projection.replace(
      "sample",
      Jason.encode!(%{id: "s-1", title: "Ticket", issue_type: "task", status: "open"})
    )

    Req.Test.stub(__MODULE__, fn conn -> ForemanWeb.Endpoint.call(conn, []) end)
    :ok
  end

  defp run(args) do
    outside = System.tmp_dir!()
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn ->
            assert CLI.run(args, req_options: [plug: {Req.Test, __MODULE__}], cwd: outside) == 0
          end)

        send(parent, {:stdout, stdout})
      end)

    assert_received {:stdout, stdout}
    {String.trim(stdout), String.trim(stderr)}
  end

  defp in_pane(pane, session) do
    System.put_env("TMUX", "/private/tmp/tmux-501/default,123,0")
    System.put_env("TMUX_PANE", pane)

    if session,
      do: System.put_env("FOREMAN_SESSION", session),
      else: System.delete_env("FOREMAN_SESSION")

    System.put_env("FOREMAN_ACTOR", "pi")
  end

  test "ask sends FOREMAN_SESSION, $TMUX_PANE and the tmux server" do
    in_pane("%12", "b1")

    assert {:ok, %{request: request}} =
             CLI.parse(["ask", "decision", "s-1"] ++ @facts)

    assert %{
             "session" => "b1",
             "tmux_pane" => "%12",
             "tmux_socket" => "/private/tmp/tmux-501/default"
           } =
             request

    # Outside tmux the fields are empty and the ask still parses.
    System.delete_env("TMUX")
    System.delete_env("TMUX_PANE")
    assert {:ok, %{request: request}} = CLI.parse(["ask", "decision", "s-1"] ++ @facts)
    assert %{"tmux_pane" => nil, "tmux_socket" => nil} = request
  end

  test "ask from a registered pane prints only the ID and stores the pane's row" do
    {:ok, %{id: id}} =
      Foreman.SessionRegistry.register(%{
        "name" => "b1",
        "pane" => "%12",
        "workdir" => "/tmp",
        "harness" => "pi"
      })

    in_pane("%12", nil)
    {stdout, stderr} = run(["ask", "decision", "s-1", "--project", "sample"] ++ @facts)
    assert {:ok, _} = Ecto.UUID.cast(stdout)
    assert stderr == ""
    assert Foreman.Requests.get(stdout).agent_session_id == id
  end

  test "ask from an unregistered shell is accepted and prints the Decision 5 warning" do
    in_pane("%77", "nobody")
    {stdout, stderr} = run(["ask", "decision", "s-1", "--project", "sample"] ++ @facts)

    assert {:ok, _} = Ecto.UUID.cast(stdout)

    assert stderr ==
             "The board does not know this session (name nobody, pane %77). The card shows that the source is unknown."

    request = Foreman.Requests.get(stdout)
    assert {request.state, request.agent_session_id} == {"pending", nil}

    # --json keeps the request ID and the warning, and never the "not accepted" warning key.
    {json, _} = run(["ask", "decision", "s-1", "--project", "sample", "--json"] ++ @facts)
    body = Jason.decode!(json)
    assert {:ok, _} = Ecto.UUID.cast(body["id"])
    assert body["session_warning"] =~ "The board does not know this session"
    refute Map.has_key?(body, "warning")
  end

  test "dispatch --name --pi-session: the build's own name, the caller as parent" do
    in_pane("%1", "coord")

    {:ok, _} =
      Foreman.SessionRegistry.register(%{
        "name" => "coord",
        "pane" => "%1",
        "workdir" => "/tmp",
        "harness" => "claude"
      })

    pi = Ecto.UUID.generate()

    assert {:ok, %{request: request}} =
             CLI.parse(~w(dispatch s-1 --name b2 --pi-session #{pi} --window %3 --harness pi))

    assert request["session"] == "coord"
    assert %{"name" => "b2", "pi_session" => ^pi, "window" => "%3"} = request["payload"]

    {_, stderr} =
      run(~w(dispatch s-1 --project sample --name b2 --pi-session #{pi} --window %3 --harness pi))

    assert stderr == ""
    build = AgentSessions.live_by_name("b2")
    assert {build.kind, build.pane_id, build.conversation_id} == {"build", "%3", pi}
    assert build.parent_id == AgentSessions.live_by_name("coord").id
  end

  test "older dispatch callers without --name still work" do
    in_pane("%1", "b3")

    assert {:ok, %{request: request}} =
             CLI.parse(~w(dispatch s-1 --session b3 --window b3 --harness pi))

    assert request["session"] == "b3"
    refute Map.has_key?(request["payload"], "name")

    assert {:error, "dispatch requires --name <build-name> (or the older --session <build-name>)"} =
             CLI.parse(~w(dispatch s-1 --window %3))
  end

  test "session register takes $TMUX_PANE and --parent; old callers still work" do
    in_pane("%21", "relay-1")

    assert {:ok, %{request: request}} =
             CLI.parse(
               ~w(session register --name relay-1 --workdir /tmp --harness pi --parent coord)
             )

    assert %{"pane" => "%21", "parent" => "coord", "action" => "session_register"} = request

    assert {:ok, %{request: old}} =
             CLI.parse(~w(session register --name c --pane %5 --workdir /tmp --harness claude))

    assert old["pane"] == "%5"
    refute Map.has_key?(old, "parent")

    System.delete_env("TMUX_PANE")
    assert {:error, _} = CLI.parse(~w(session register --name c --workdir /tmp --harness claude))

    {:ok, _} =
      Foreman.SessionRegistry.register(%{
        "name" => "coord",
        "pane" => "%1",
        "workdir" => "/tmp",
        "harness" => "claude"
      })

    in_pane("%21", "relay-1")

    {json, _} =
      run(~w(session register --name relay-1 --workdir /tmp --harness pi --parent coord --json))

    assert %{"name" => "relay-1", "pane" => "%21", "id" => id} = Jason.decode!(json)
    assert AgentSessions.get(id).parent_id == AgentSessions.live_by_name("coord").id
  end
end
