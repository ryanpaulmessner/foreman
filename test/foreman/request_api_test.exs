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

  test "batch CLI posts one card and wait preserves checked ids through HTTP" do
    opts = [req_options: [plug: {Req.Test, __MODULE__}]]

    for answer <- [["timeout"], []] do
      args = [
        "ask",
        "batch",
        "s-1",
        "--project",
        "sample",
        "--question",
        "File tickets?",
        "--text",
        "What: Findings\nPart of: Sweep\nWhy now: Ready",
        "--item",
        "timeout=Fix timeout",
        "--item",
        "layout=Fix layout"
      ]

      id = capture_io(fn -> assert CLI.run(args, opts) == 0 end) |> String.trim()
      assert {:ok, _} = Ecto.UUID.cast(id)
      assert Requests.get(id).kind == "batch"
      {:ok, _} = Requests.resolve(id, :answer, %{"answer" => answer})
      wire = capture_io(fn -> CLI.run(["wait", id], opts) end) |> Jason.decode!()
      assert wire["state"] == "answered"
      assert wire["outcome"] == %{"answer" => answer}
    end
  end

  test "broadcast CLI routes through HTTP instead of local ticket notes" do
    opts = [req_options: [plug: {Req.Test, __MODULE__}]]

    args = [
      "note",
      "--all-coordinators",
      "Use MIX_TEST_PARTITION",
      "--actor",
      "claude",
      "--session",
      "source",
      "--json"
    ]

    wire = capture_io(fn -> assert CLI.run(args, opts) == 0 end) |> Jason.decode!()
    assert wire == %{"delivered" => [], "skipped" => []}
  end

  test "update CLI edits the existing card and returns a terminal refusal with state" do
    {:ok, r} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "actor" => "pi",
        "session" => "build",
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Which date?"})
      })

    opts = [req_options: [plug: {Req.Test, __MODULE__}]]

    args = [
      "ask",
      "update",
      r.id,
      "--question",
      "Which Friday?",
      "--actor",
      "pi",
      "--session",
      "build",
      "--json"
    ]

    body = capture_io(fn -> CLI.run(args, opts) end) |> Jason.decode!()
    assert body["id"] == r.id
    assert Requests.get(r.id).facts["question"] == "Which Friday?"
    Requests.resolve(r.id, :wrong_question, %{"note" => "Friday is a holiday"})
    wait = capture_io(fn -> CLI.run(["wait", r.id], opts) end) |> Jason.decode!()
    assert wait["state"] == "wrong_question"
    assert wait["note"] == "Friday is a holiday"
    refused = capture_io(fn -> CLI.run(args, opts) end) |> Jason.decode!()
    assert refused["error"] == "not_pending"
    assert refused["state"] == "wrong_question"
  end

  test "standing answers survive the HTTP refusal wire format and plain CLI output" do
    facts =
      Foreman.DecisionFacts.valid(%{
        "question" => "Should we bypass login for previews?",
        "options" => ["Yes", "No"]
      })

    {:ok, r} = Requests.ask({"sample", "s-1"}, "decision", %{"facts" => facts})
    Requests.resolve(r.id, :answer, %{"answer" => "No", "always" => true})
    opts = [req_options: [plug: {Req.Test, __MODULE__}]]

    args = [
      "ask",
      "decision",
      "s-1",
      "--project",
      "sample",
      "--question",
      facts["question"],
      "--text",
      facts["text"],
      "--option",
      "Yes",
      "--option-detail",
      "Yes=Bypass",
      "--option",
      "No",
      "--option-detail",
      "No=Keep login"
    ]

    refused = capture_io(fn -> CLI.run(args, opts) end) |> Jason.decode!()
    assert refused["error"] == "already_answered"
    assert refused["standing_answer"]["answer"] == "No"
    close_args = List.replace_at(args, 6, "Should we bypass login for all previews?")
    accepted = capture_io(fn -> CLI.run(close_args, opts) end) |> Jason.decode!()
    assert accepted["state"] == "pending"
    assert accepted["standing_answer"]["answer"] == "No"
    assert Requests.get(accepted["id"])
  end

  test "chore CLI joins one card and both IDs wait for Done" do
    opts = [req_options: [plug: {Req.Test, __MODULE__}]]

    args = [
      "ask",
      "chore",
      "s-1",
      "--project",
      "sample",
      "--question",
      "Sign in",
      "--step",
      "Open preview",
      "--step",
      "Sign in",
      "--key",
      "signin:host"
    ]

    first = capture_io(fn -> CLI.run(args, opts) end) |> String.trim()
    second = capture_io(fn -> CLI.run(args, opts) end) |> String.trim()
    assert first == second
    assert {:ok, _} = Requests.resolve(first, :complete, %{})

    for id <- [first, second] do
      outcome = capture_io(fn -> CLI.run(["wait", id], opts) end) |> Jason.decode!()
      assert outcome["state"] == "done"
    end
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

  test "screenshot refusal prints the review_ui command in plain output" do
    opts = [req_options: [plug: {Req.Test, __MODULE__}]]

    output =
      capture_io(fn ->
        CLI.run(
          [
            "ask",
            "decision",
            "s-1",
            "--project",
            "sample",
            "--question",
            "Does layout.png look right?",
            "--text",
            "What: Layout\nPart of: Cards\nWhy now: Review"
          ],
          opts
        )
      end)

    assert output =~ "card_unclear:"

    assert output =~
             "screenshots go on a review_ui card: foreman ask review_ui <ticket> --image <file-or-folder>"

    refute output =~ "unavailable"
    assert Requests.pending_count() == 0
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

  test "wait --any prints the same server request JSON as plain wait" do
    {:ok, first} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "First?"})
      })

    {:ok, second} =
      Requests.ask({"sample", "s-1"}, "decision", %{
        "facts" => Foreman.DecisionFacts.valid(%{"question" => "Second?"})
      })

    {:ok, _} = Requests.resolve(second.id, :answer, %{"answer" => "B"})
    opts = [req_options: [plug: {Req.Test, __MODULE__}]]

    single =
      capture_io(fn -> assert CLI.run(["wait", second.id, "--timeout", "0"], opts) == 0 end)

    any =
      capture_io(fn ->
        assert CLI.run(["wait", "--any", first.id, second.id, "--timeout", "0"], opts) == 0
      end)

    assert Jason.decode!(any) == Jason.decode!(single)
    assert Jason.decode!(any)["id"] == second.id
    assert Jason.decode!(any)["state"] == "answered"
  end

  test "wait --any returns the full second request when it resolves first" do
    result = %{
      "id" => "b",
      "state" => "answered",
      "outcome" => %{"answer" => "B"},
      "note" => "chosen"
    }

    for {id, body} <- [
          {"a", %{"state" => "pending"}},
          {"b", %{"state" => "executing"}},
          {"a", %{"state" => "approved"}},
          {"b", result}
        ] do
      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, bytes, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(bytes)["id"] == id
        Req.Test.json(conn, body)
      end)
    end

    output =
      capture_io(fn ->
        assert CLI.run(["wait", "--any", "a", "b", "--timeout", "1"],
                 poll_interval: 0,
                 req_options: [plug: {Req.Test, __MODULE__}]
               ) == 0
      end)

    assert Jason.decode!(output) == result
  end

  test "wait --any immediately returns every resolved state unchanged" do
    for state <- ~w(answered done declined withdrawn wrong_question failed superseded) do
      result = %{"id" => "b", "state" => state, "outcome" => %{}, "note" => nil}

      Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, %{id: "a", state: "pending"}) end)

      Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, result) end)

      output =
        capture_io(fn ->
          assert CLI.run(["wait", "--any", "a", "b", "--timeout", "0"],
                   req_options: [plug: {Req.Test, __MODULE__}]
                 ) == 0
        end)

      assert Jason.decode!(output) == result
    end
  end

  test "wait --any timeout preserves the current snapshot and names all ids" do
    for state <- ~w(pending approved executing) do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{id: "a", state: state}) end)

      output =
        capture_io(fn ->
          assert CLI.run(["wait", "--any", "a", "b", "--timeout", "0"],
                   req_options: [plug: {Req.Test, __MODULE__}]
                 ) == 0
        end)

      assert Jason.decode!(output) == %{"id" => "a", "state" => state, "ids" => ["a", "b"]}
    end
  end

  test "wait --any reports an unknown id even when another request is resolved" do
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, %{id: "a", state: "answered"}) end)

    Req.Test.expect(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{error: "not_found"})
    end)

    warning =
      capture_io(:stderr, fn ->
        output =
          capture_io(fn ->
            assert CLI.run(["wait", "--any", "a", "missing", "--timeout", "1"],
                     poll_interval: 0,
                     req_options: [plug: {Req.Test, __MODULE__}]
                   ) == 0
          end)

        assert %{"id" => "missing", "ids" => ["a", "missing"], "error" => "not_found"} =
                 Jason.decode!(output)
      end)

    assert warning == ""
  end

  test "wait --any retains the snapshot through an outage until the deadline" do
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, %{id: "a", state: "executing"}) end)

    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, %{id: "b", state: "pending"}) end)
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)

    warning =
      capture_io(:stderr, fn ->
        output =
          capture_io(fn ->
            assert CLI.run(["wait", "--any", "a", "b", "--timeout", "1"],
                     poll_interval: 100,
                     req_options: [plug: {Req.Test, __MODULE__}]
                   ) == 0
          end)

        assert Jason.decode!(output) == %{
                 "id" => "a",
                 "state" => "executing",
                 "ids" => ["a", "b"]
               }
      end)

    assert String.trim(warning) == "warning: wait poll failed; retrying until the deadline"
    assert Repo.aggregate("spooled_events", :count) == 0
  end

  test "wait --any with no successful poll names every id on timeout" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)

    capture_io(:stderr, fn ->
      output =
        capture_io(fn ->
          assert CLI.run(["wait", "--any", "a", "b", "--timeout", "0"],
                   req_options: [plug: {Req.Test, __MODULE__}]
                 ) == 0
        end)

      assert Jason.decode!(output) == %{
               "warning" => "foreman unavailable; read was not queued",
               "ids" => ["a", "b"]
             }
    end)
  end

  test "wait argument parsing requires ids and keeps the single-id envelope" do
    assert {:ok, %{request: %{"action" => "wait", "id" => "a", "timeout" => 300}, json: true}} =
             CLI.parse(["wait", "a"])

    assert {:ok,
            %{request: %{"action" => "wait", "ids" => ["a", "b"], "timeout" => 2}, json: true}} =
             CLI.parse(["wait", "--any", "a", "b", "--timeout", "2"])

    for args <- [["wait", "--any"], ["wait", "a", "b"], ["wait", "--any", "a", "--timeout", "-1"]] do
      assert {:error, _} = CLI.parse(args)
    end
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

  test "20 flaps within 60 seconds print one warning for both wait forms" do
    responses =
      for n <- 0..19,
          pair <- [{n * 2_000, %{}}, {n * 2_000 + 1_000, %{"state" => "pending"}}],
          do: pair

    for args <- [["wait", "a"], ["wait", "--any", "a", "b"]] do
      assert timed_wait(args, responses ++ [{40_000, %{"state" => "answered"}}]) ==
               ["warning: wait poll failed; retrying until the deadline"]
    end
  end

  test "a two-minute outage and a new outage 70 seconds after recovery print two warnings" do
    responses = [
      {0, %{}},
      {120_000, %{"state" => "pending"}},
      {190_000, %{}},
      {191_000, %{"state" => "answered"}}
    ]

    for args <- [["wait", "a"], ["wait", "--any", "a", "b"]] do
      assert timed_wait(args, responses) == [
               "warning: wait poll failed; retrying until the deadline",
               "wait polling recovered",
               "warning: wait poll failed; retrying until the deadline"
             ]
    end
  end

  test "continuous failures warn at the 60-second boundary and recovery at ten seconds" do
    assert timed_wait(["wait", "a"], [
             {0, %{}},
             {59_999, %{}},
             {60_000, %{}},
             {119_999, %{}},
             {120_000, %{}},
             {120_001, %{"state" => "answered"}}
           ]) == [
             "warning: wait poll failed; retrying until the deadline",
             "warning: wait poll failed; retrying until the deadline",
             "warning: wait poll failed; retrying until the deadline",
             "wait polling recovered"
           ]

    for {duration, recovery} <- [{9_999, []}, {10_000, ["wait polling recovered"]}] do
      assert timed_wait(["wait", "a"], [{0, %{}}, {duration, %{"state" => "answered"}}]) ==
               ["warning: wait poll failed; retrying until the deadline"] ++ recovery
    end
  end

  defp timed_wait(args, responses) do
    clock = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

    for {time, body} <- responses do
      Req.Test.expect(__MODULE__, fn conn ->
        Agent.update(clock, fn _ -> time end)
        Req.Test.json(conn, body)
      end)

      if "--any" in args do
        Req.Test.expect(__MODULE__, fn conn ->
          Req.Test.json(conn, %{id: "b", state: "pending"})
        end)
      end
    end

    capture_io(:stderr, fn ->
      output =
        capture_io(fn ->
          assert CLI.run(args ++ ["--timeout", "7200"],
                   poll_interval: 0,
                   monotonic_time: fn -> Agent.get(clock, & &1) end,
                   req_options: [plug: {Req.Test, __MODULE__}]
                 ) == 0
        end)

      assert Jason.decode!(output)["state"] == "answered"
    end)
    |> String.trim()
    |> String.split("\n")
  end

  test "quick outages do not reset the warning limit or announce recovery" do
    for args <- [["wait", "a"], ["wait", "--any", "a", "b"]] do
      for body <- [%{}, %{}, %{"state" => "pending"}, %{}, %{"state" => "answered"}] do
        Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, body) end)

        if "--any" in args do
          Req.Test.expect(__MODULE__, fn conn ->
            Req.Test.json(conn, %{id: "b", state: "pending"})
          end)
        end
      end

      warning =
        capture_io(:stderr, fn ->
          output =
            capture_io(fn ->
              assert CLI.run(args ++ ["--timeout", "1"],
                       poll_interval: 0,
                       req_options: [plug: {Req.Test, __MODULE__}]
                     ) == 0
            end)

          assert Jason.decode!(output)["state"] == "answered"
        end)

      assert String.split(String.trim(warning), "\n") == [
               "warning: wait poll failed; retrying until the deadline"
             ]
    end
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
