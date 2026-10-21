defmodule Foreman.Week.MergedPrs do
  @moduledoc "Paginated GitHub merged-PR reads, bounded by a lookback date."
  @query "query($search:String!,$cursor:String) { search(query:$search,type:ISSUE,first:100,after:$cursor) { issueCount pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { number title body headRefName baseRefName headRefOid url } } } }"

  def list(remote, days, opts) do
    if is_binary(remote) and Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, remote) and
         is_binary(opts[:token]) and opts[:token] != "" do
      since = Date.add(Keyword.get(opts, :today, Date.utc_today()), -days)
      search = "repo:#{remote} is:pr is:merged merged:>=#{since}"
      pages(search, nil, MapSet.new(), [], opts)
    else
      {:error, :credentials_or_remote}
    end
  end

  defp pages(search, cursor, seen, acc, opts) do
    request =
      [
        url: "https://api.github.com/graphql",
        auth: {:bearer, opts[:token]},
        json: %{query: @query, variables: %{search: search, cursor: cursor}},
        retry: false,
        redirect: false,
        receive_timeout: 15_000
      ] ++ Keyword.take(opts, [:plug])

    case Req.post(request) do
      {:ok, %{status: 200, body: %{"errors" => _}}} ->
        {:error, :graphql}

      {:ok, %{status: 200, body: %{"data" => %{"search" => result}}}} ->
        decode(result, search, seen, acc, opts)

      {:ok, %{status: status}} when status in [403, 429] ->
        {:error, :rate_limited}

      _ ->
        {:error, :unavailable}
    end
  end

  defp decode(
         %{"issueCount" => count, "nodes" => nodes, "pageInfo" => page},
         search,
         seen,
         acc,
         opts
       )
       when is_integer(count) and count <= 1000 and is_list(nodes) do
    prs =
      Enum.map(nodes, fn pr ->
        true = is_integer(pr["number"]) and pr["number"] > 0
        true = Enum.all?(~w(title headRefName baseRefName headRefOid url), &is_binary(pr[&1]))
        true = String.starts_with?(pr["url"], "https://github.com/")

        %{
          "number" => pr["number"],
          "title" => pr["title"],
          "body" => pr["body"],
          "source_branch" => pr["headRefName"],
          "target_branch" => pr["baseRefName"],
          "head_sha" => pr["headRefOid"],
          "url" => pr["url"],
          "state" => "merged"
        }
      end)

    next = page["endCursor"]

    cond do
      page["hasNextPage"] == false ->
        {:ok, acc ++ prs}

      page["hasNextPage"] == true and is_binary(next) and not MapSet.member?(seen, next) ->
        pages(search, next, MapSet.put(seen, next), acc ++ prs, opts)

      true ->
        {:error, :incomplete}
    end
  rescue
    _ -> {:error, :invalid_response}
  end

  defp decode(_, _, _, _, _), do: {:error, :incomplete}
end
