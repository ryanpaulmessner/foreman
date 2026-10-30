defmodule Foreman.RequestAPITest do
  use Foreman.DataCase, async: false
  import ExUnit.CaptureIO
  alias Foreman.{AgentCommands, CLI, Overlay, Requests, Repo}

  setup do
    Overlay.backfill("sample", [%{bead_id: "s-1", status: "open", issue_type: "task"}])

    {:ok, config} =
      Foreman.Config.parse_layers([{"defaults", File.read!("priv/foreman.defaults.toml")}])

    config =
      Map.put(config, "repos", [%{"key" => "sample", "path" => "/tmp/sample", "enabled" => true}])

    Repo.insert_all("board_config", [
      %{id: 1, config: config, source: "test", discovered: [], loaded_at: DateTime.utc_now()}
    ])

    path = Path.join(System.tmp_dir!(), "inbox-token-#{System.unique_integer([:positive])}")
    File.write!(path, "test-only-token-long")
    old = Application.get_env(:foreman, :token_file)
    Application.put_env(:foreman, :token_file, path)

    on_exit(fn ->
      File.rm!(path)
      Application.put_env(:foreman, :token_file, old)
    end)

    Req.Test.stub(__MODULE__, fn conn -> ForemanWeb.Endpoint.call(conn, []) end)
    :ok
  end

  test "ask returns id immediately; wait timeout returns current state, then answer or decline" do
    opts = [req_options: [plug: {Req.Test, __MODULE__}]]

    output =
      capture_io(fn ->
        assert CLI.run(
                 [
                   "ask",
                   "decision",
                   "s-1",
                   "--project",
                   "sample",
                   "--question",
                   "Which?",
                   "--option",
                   "A",
                   "--option",
                   "B",
                   "--recommendation",
                   "B",
                   "--option-detail",
                   "B=Keep the compact layout",
                   "--option-detail",
                   "A=Use wide layout",
                   "--text",
                   "What: Layout\nPart of: Cards\nWhy now: Review",
                   "--actor",
                   "pi",
                   "--session",
                   "build"
                 ],
                 opts
               ) == 0
      end)

    id = String.trim(output)
    assert {:ok, _} = Ecto.UUID.cast(id)
    request = Requests.get(id)

    assert request.facts["option_details"] == %{
             "A" => "Use wide layout",
             "B" => "Keep the compact layout"
           }

    assert request.facts["options"] == ["A", "B"]
    assert request.session == "build"
    output = capture_io(fn -> assert CLI.run(["wait", id, "--timeout", "0"], opts) == 0 end)
    assert Jason.decode!(output)["state"] == "pending"
    Requests.resolve(id, :decline, %{"note" => "Later"})
    output = capture_io(fn -> assert CLI.run(["wait", id], opts) == 0 end)
    assert %{"state" => "declined", "note" => "Later"} = Jason.decode!(output)
  end

  test "withdraw CLI returns withdrawn through wait and refuses a second withdrawal" do
    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "actor" => "pi",
        "session" => "build",
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Which?"})
      })

    opts = [req_options: [plug: {Req.Test, __MODULE__}]]

    args = [
      "withdraw",
      request.id,
      "--actor",
      "pi",
      "--session",
      "build",
      "--reason",
      "Answered in chat",
      "--json"
    ]

    output = capture_io(fn -> assert CLI.run(args, opts) == 0 end)
    assert Jason.decode!(output)["state"] == "withdrawn"
    output = capture_io(fn -> CLI.run(["wait", request.id], opts) end)

    assert %{"state" => "withdrawn", "outcome" => %{"reason" => "Answered in chat"}} =
             Jason.decode!(output)

    output = capture_io(fn -> CLI.run(args, opts) end)
    assert Jason.decode!(output)["warning"] =~ "invalid"
  end

  test "a non-JSON refusal remains a refusal, not an unavailable service" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 422, "Invalid") end)

    output =
      capture_io(fn ->
        CLI.run(["ask", "decision", "s-1", "--json"], req_options: [plug: {Req.Test, __MODULE__}])
      end)

    assert Jason.decode!(output)["error"] == "invalid request"
  end

  test "lint refusal lists missing parts in plain output and JSON" do
    opts = [req_options: [plug: {Req.Test, __MODULE__}]]

    args = [
      "ask",
      "decision",
      "s-1",
      "--project",
      "sample",
      "--question",
      "Which?",
      "--option",
      "A"
    ]

    output = capture_io(fn -> CLI.run(args, opts) end)
    assert output =~ "card_unclear: Missing What, Part of, Why now, option detail: A"
    output = capture_io(fn -> CLI.run(args ++ ["--json"], opts) end)
    assert Jason.decode!(output)["missing"] == ["What", "Part of", "Why now", "option detail: A"]
  end

  test "malformed option details are usage errors, not transport failures" do
    output =
      capture_io(fn ->
        CLI.run(["ask", "decision", "s-1", "--option-detail", "bad", "--json"])
      end)

    assert Jason.decode!(output)["warning"] =~ "usage"
  end

  test "withdraw replay is idempotent" do
    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "actor" => "pi",
        "session" => "build",
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Which?"})
      })

    envelope = %{
      "action" => "withdraw",
      "id" => request.id,
      "actor" => "pi",
      "session" => "build",
      "reason" => "Answered",
      "request_id" => Ecto.UUID.generate()
    }

    assert {200, _} = AgentCommands.execute(envelope)
    assert {200, _} = AgentCommands.execute(envelope)
    assert Repo.aggregate("request_events", :count) == 2
  end

  test "ask retries are idempotent and worker observations are not agent commands" do
    envelope = %{
      "action" => "ask",
      "repo" => "sample",
      "id" => "s-1",
      "request_kind" => "decision",
      "facts" => Foreman.DecisionFacts.valid(%{"question" => "Which?"}),
      "request_id" => Ecto.UUID.generate()
    }

    assert {200, first} = AgentCommands.execute(envelope)
    assert first.id == envelope["request_id"]
    assert {200, repeat} = AgentCommands.execute(envelope)
    assert Jason.decode!(Jason.encode!(first)) == repeat
    assert Requests.pending_count() == 1

    assert {422, _} =
             AgentCommands.execute(%{
               "action" => "succeeded",
               "id" => first.id,
               "repo" => "sample"
             })

    assert {404, _} = AgentCommands.execute(%{"action" => "wait", "id" => "bad"})
  end

  test "offline replay keeps the ask id that was returned in the spool receipt" do
    id = Ecto.UUID.generate()

    request = %{
      "action" => "ask",
      "repo" => "sample",
      "id" => "s-1",
      "request_kind" => "decision",
      "facts" => Foreman.DecisionFacts.valid(%{"question" => "Offline?"}),
      "request_id" => id
    }

    assert :ok = Foreman.Spool.enqueue(request)
    assert :ok = Foreman.Spool.replay()
    assert Requests.get(id).state == "pending"
    assert :ok = Foreman.Spool.replay()
    assert Requests.pending_count() == 1
  end

  test "ask refusals and wait usage errors always exit zero" do
    opts = [req_options: [plug: {Req.Test, __MODULE__}]]

    output =
      capture_io(fn ->
        assert CLI.run(["ask", "push", "s-1", "--project", "sample", "--json"], opts) == 0
      end)

    assert Jason.decode!(output)["warning"] =~ "not_committed"
    output = capture_io(fn -> assert CLI.run(["wait", "bad", "--timeout", "-1"], opts) == 0 end)
    assert Jason.decode!(output)["warning"] =~ "usage"
    assert Requests.pending_count() == 0
  end

  test "wait retries failed polls before returning an answer" do
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{state: "answered", outcome: %{answer: "B"}})
    end)

    output =
      capture_io(fn ->
        warning =
          capture_io(:stderr, fn ->
            CLI.run(["wait", Ecto.UUID.generate(), "--timeout", "1"],
              poll_interval: 0,
              req_options: [plug: {Req.Test, __MODULE__}]
            )
          end)

        assert warning =~ "wait poll failed"
      end)

    assert %{"state" => "answered", "outcome" => %{"answer" => "B"}} = Jason.decode!(output)
  end

  test "wait warns once per failure streak and resets after recovery" do
    for body <- [%{}, %{}, %{"state" => "pending"}, %{}, %{"state" => "answered"}] do
      Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, body) end)
    end

    warning =
      capture_io(:stderr, fn ->
        output =
          capture_io(fn ->
            CLI.run(["wait", Ecto.UUID.generate(), "--timeout", "1"],
              poll_interval: 0,
              req_options: [plug: {Req.Test, __MODULE__}]
            )
          end)

        assert Jason.decode!(output)["state"] == "answered"
      end)

    assert length(String.split(String.trim(warning), "\n")) == 2
  end

  test "deadline does not start another transport call" do
    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), :wait_polled)
      Req.Test.json(conn, %{state: "pending"})
    end)

    capture_io(fn ->
      CLI.run(["wait", Ecto.UUID.generate(), "--timeout", "1"],
        poll_interval: 2000,
        req_options: [plug: {Req.Test, __MODULE__}]
      )
    end)

    assert_received :wait_polled
    refute_received :wait_polled
  end

  test "deadline returns the last authoritative snapshot after failed polls" do
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, %{state: "pending"}) end)
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)

    capture_io(:stderr, fn ->
      output =
        capture_io(fn ->
          CLI.run(["wait", Ecto.UUID.generate(), "--timeout", "1"],
            poll_interval: 100,
            req_options: [plug: {Req.Test, __MODULE__}]
          )
        end)

      assert Jason.decode!(output) == %{"state" => "pending"}
    end)
  end

  test "wait polls until the outcome and never spools a read" do
    {:ok, request} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Which?"})
      })

    Req.Test.stub(__MODULE__, fn conn ->
      Requests.resolve(request.id, :answer, %{"answer" => "B"})
      ForemanWeb.Endpoint.call(conn, [])
    end)

    output =
      capture_io(fn ->
        assert CLI.run(["wait", request.id], req_options: [plug: {Req.Test, __MODULE__}]) == 0
      end)

    assert %{"state" => "answered", "outcome" => %{"answer" => "B"}} = Jason.decode!(output)

    output =
      capture_io(fn ->
        capture_io(:stderr, fn ->
          assert CLI.run(["wait", request.id, "--timeout", "0"], url: "http://127.0.0.1:1") == 0
        end)
      end)

    assert Jason.decode!(output)["warning"]
    assert Repo.aggregate("spooled_events", :count) == 0
  end
end
