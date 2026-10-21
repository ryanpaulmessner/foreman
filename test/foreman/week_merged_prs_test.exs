defmodule Foreman.Week.MergedPrsTest do
  use ExUnit.Case, async: true

  test "merged search uses the lookback and follows every page" do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = Jason.decode!(body)
      assert params["variables"]["search"] == "repo:org/repo is:pr is:merged merged:>=2026-09-30"
      cursor = params["variables"]["cursor"]
      n = if cursor, do: 2, else: 1

      data = %{
        "data" => %{
          "search" => %{
            "issueCount" => 2,
            "pageInfo" => %{"hasNextPage" => is_nil(cursor), "endCursor" => "next"},
            "nodes" => [
              %{
                "number" => n,
                "title" => "rs-one",
                "body" => "rs-one",
                "headRefName" => "feature",
                "baseRefName" => "staging",
                "headRefOid" => String.duplicate("a", 40),
                "url" => "https://github.com/org/repo/pull/#{n}"
              }
            ]
          }
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(data))
    end

    assert {:ok, [%{"number" => 1, "state" => "merged"}, %{"number" => 2}]} =
             Foreman.Week.MergedPrs.list("org/repo", 21,
               token: "test",
               today: ~D[2026-10-21],
               plug: plug
             )
  end
end
