defmodule Foreman.ForgeGitHubTest do
  use ExUnit.Case, async: true
  alias Foreman.Forge.GitHub

  test "a single read observes a tracked merged PR as well as open PRs" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      query = Jason.decode!(body)["query"]
      assert query =~ "pr3: pullRequest(number:3)"
      refute query =~ "mutation"
      Req.Test.json(conn, fixture("form-engine-tracked.json"))
    end)

    assert {:ok, snapshot} =
             GitHub.list("rpmessner/form-engine",
               token: "test",
               tracked: [3],
               plug: {Req.Test, __MODULE__}
             )

    assert Enum.find(snapshot["change_requests"], &(&1["number"] == 3))["state"] == "merged"
  end

  test "PRs carry the time they were opened, when GitHub sends it" do
    response =
      update_in(fixture("form-engine.json"), ["data", "repository", "pullRequests", "nodes"], fn
        [first | rest] -> [Map.put(first, "createdAt", "2026-11-01T10:00:00Z") | rest]
      end)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["query"] =~ "createdAt"
      Req.Test.json(conn, response)
    end)

    assert {:ok, %{"change_requests" => [first | rest]}} =
             GitHub.list("owner/repo", token: "test", plug: {Req.Test, __MODULE__})

    assert first["created_at"] == "2026-11-01T10:00:00Z"
    assert Enum.all?(rest, &is_nil(&1["created_at"]))
  end

  test "incomplete pagination, missing tracked PRs and GraphQL errors never publish partial data" do
    for response <- [
          put_in(
            fixture("form-engine.json"),
            ["data", "repository", "pullRequests", "pageInfo", "hasNextPage"],
            true
          ),
          %{
            "errors" => [%{"message" => "private upstream details"}],
            "data" => fixture("form-engine.json")["data"]
          }
        ] do
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, response))

      assert {:error, reason} =
               GitHub.list("owner/repo", token: "test", plug: {Req.Test, __MODULE__})

      assert reason in [:incomplete, :graphql]
    end

    Req.Test.stub(__MODULE__, &Req.Test.json(&1, fixture("form-engine.json")))

    assert {:error, :incomplete} =
             GitHub.list("owner/repo", token: "test", tracked: [3], plug: {Req.Test, __MODULE__})
  end

  test "GraphQL rate-limit errors use the same cooldown as HTTP rate limiting" do
    Req.Test.stub(
      __MODULE__,
      &Req.Test.json(&1, %{"errors" => [%{"type" => "RATE_LIMITED", "message" => "limited"}]})
    )

    assert {:error, :rate_limited} =
             GitHub.list("owner/repo", token: "test", plug: {Req.Test, __MODULE__})
  end

  test "malformed CR identity is rejected rather than published" do
    response =
      update_in(fixture("form-engine.json"), ["data", "repository", "pullRequests", "nodes"], fn [
                                                                                                   first
                                                                                                   | rest
                                                                                                 ] ->
        [Map.put(first, "number", nil) | rest]
      end)

    Req.Test.stub(__MODULE__, &Req.Test.json(&1, response))

    assert {:error, :invalid_response} =
             GitHub.list("owner/repo", token: "test", plug: {Req.Test, __MODULE__})
  end

  test "branch pagination does not break existing PR reads or omit later branches" do
    sha = String.duplicate("a", 40)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      query = Jason.decode!(body)

      refs =
        if query["variables"]["cursor"] == "page-2" do
          %{
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => "end"},
            "nodes" => [%{"name" => "later", "target" => %{"oid" => sha}}]
          }
        else
          %{
            "pageInfo" => %{"hasNextPage" => true, "endCursor" => "page-2"},
            "nodes" => [%{"name" => "main", "target" => %{"oid" => sha}}]
          }
        end

      Req.Test.json(
        conn,
        put_in(fixture("form-engine.json"), ["data", "repository", "refs"], refs)
      )
    end)

    assert {:ok, snapshot} =
             GitHub.list("owner/repo", token: "test", plug: {Req.Test, __MODULE__})

    assert snapshot["branches"] == %{"main" => sha, "later" => sha}
    assert length(snapshot["change_requests"]) == 2
  end

  test "a rate-limited branch continuation retains the snapshot and cooldown classification" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      if Jason.decode!(body)["variables"]["cursor"] do
        Req.Test.json(conn, %{"errors" => [%{"type" => "RATE_LIMITED"}]})
      else
        refs = %{"pageInfo" => %{"hasNextPage" => true, "endCursor" => "next"}, "nodes" => []}

        Req.Test.json(
          conn,
          put_in(fixture("form-engine.json"), ["data", "repository", "refs"], refs)
        )
      end
    end)

    assert {:error, :rate_limited} =
             GitHub.list("owner/repo", token: "test", plug: {Req.Test, __MODULE__})
  end

  test "missing credentials fail without making a request" do
    assert {:error, :credentials_or_remote} = GitHub.list("owner/repo", [])
  end

  test "mutation failures are sanitized and neither redirects nor transport errors retry" do
    opts = [token: "test", plug: {Req.Test, __MODULE__}]

    for {status, reason} <- [
          {301, :outcome_unknown},
          {401, :unauthorized},
          {403, :forbidden_or_rate_limited},
          {404, :not_found},
          {405, :merge_refused},
          {409, :head_moved},
          {422, :merge_refused},
          {429, :forbidden_or_rate_limited},
          {503, :outcome_unknown}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        send(self(), :mutation)

        conn
        |> Plug.Conn.put_resp_header("location", "https://example.invalid")
        |> Plug.Conn.send_resp(status, "private details")
      end)

      assert {:error, ^reason} = GitHub.merge("owner/repo", 5, "confirmed", opts)
      assert_received :mutation
      refute_received :mutation
    end

    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), :mutation)
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, :outcome_unknown} = GitHub.merge("owner/repo", 5, "confirmed", opts)
    assert_received :mutation
    refute_received :mutation
    assert {:error, :outcome_unknown} = GitHub.retarget("owner/repo", 6, "main", opts)
    assert_received :mutation
    refute_received :mutation
  end

  test "create errors never leak transport details, redirect or retry" do
    facts = %{
      "head_branch" => "feature",
      "base_branch" => "main",
      "title" => "Title",
      "body" => "Body"
    }

    opts = [token: "secret-test", plug: {Req.Test, __MODULE__}]

    for {status, reason} <- [
          {301, :outcome_unknown},
          {401, :unauthorized},
          {403, :forbidden_or_rate_limited},
          {404, :not_found},
          {422, :create_refused},
          {503, :outcome_unknown}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        send(self(), :create)

        conn
        |> Plug.Conn.put_resp_header("location", "https://example.invalid")
        |> Plug.Conn.send_resp(status, "secret-test private error")
      end)

      assert {:error, ^reason} = GitHub.create_change_request("owner/repo", facts, opts)
      assert_received :create
      refute_received :create
    end

    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), :create)
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, :outcome_unknown} = GitHub.create_change_request("owner/repo", facts, opts)
    assert_received :create
    refute_received :create

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{"number" => 1, "html_url" => "https://other.invalid"})
    end)

    assert {:error, :invalid_response} = GitHub.create_change_request("owner/repo", facts, opts)

    assert {:error, :credentials_or_remote} =
             GitHub.create_change_request("owner/repo", facts, [])
  end

  test "successful HTTP status alone is not a successful mutation" do
    opts = [token: "test", plug: {Req.Test, __MODULE__}]
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{"merged" => false}))
    assert {:error, :merge_refused} = GitHub.merge("owner/repo", 5, "sha", opts)
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{"merged" => true}))
    assert {:error, :invalid_response} = GitHub.merge("owner/repo", 5, "sha", opts)
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{"number" => 6, "base" => %{"ref" => "wrong"}}))
    assert {:error, :invalid_response} = GitHub.retarget("owner/repo", 6, "main", opts)
    assert {:error, :credentials_or_remote} = GitHub.merge("owner/repo", 5, "sha", [])
    assert {:error, :credentials_or_remote} = GitHub.retarget("owner/repo", 6, "main", [])

    assert {:error, :credentials_or_remote} =
             GitHub.merge("owner/repo/../../elsewhere", 5, "sha", opts)
  end

  defp fixture(name), do: File.read!("test/fixtures/forge/" <> name) |> Jason.decode!()
end
