defmodule Foreman.Requests.OpenPr do
  @moduledoc "Immutable PR facts and live forge guards. Request success never advances a ticket."
  @behaviour Foreman.Requests.Kind

  @impl true
  def validate(_, %{stage: stage}) when stage != :committed, do: {:error, :not_committed}

  def validate(facts, row) when is_map(facts) do
    with {:ok, repo} <- Foreman.Requests.Push.configured(row.repo_key),
         :ok <- shape(facts),
         facts =
           facts
           |> Map.take(~w(head_branch expected_sha base_branch title body base_ok))
           |> Map.put("remote", repo["github"]),
         :ok <- capable(Foreman.Forge.adapter()),
         {:ok, snapshot} <- snapshot(row.repo_key, facts),
         :ok <- base_rule(repo, snapshot, facts, {row.repo_key, row.bead_id}),
         :ok <- observed_guards(row.repo_key, facts) do
      {:ok, facts}
    end
  end

  def validate(_, _), do: {:error, :invalid_facts}

  def observed_guards(key, facts) do
    with {:ok, snapshot} <- snapshot(key, facts),
         true <-
           Map.has_key?(snapshot["branches"] || %{}, facts["base_branch"]) ||
             {:error, :base_missing},
         :ok <- no_open_pr(snapshot, facts),
         :ok <- observed_head(key, facts) do
      :ok
    end
  end

  def observed_head(key, %{"expected_sha" => expected} = facts) do
    with {:ok, snapshot} <- snapshot(key, facts) do
      case get_in(snapshot, ["branches", facts["head_branch"]]) do
        nil -> {:error, :head_missing}
        ^expected -> :ok
        _ -> {:error, :head_moved}
      end
    end
  end

  defp snapshot(key, %{"remote" => expected}) do
    case Foreman.Forge.Store.get(key) do
      %{remote: ^expected, snapshot: snapshot} -> {:ok, snapshot}
      _ -> {:error, :forge_snapshot_required}
    end
  end

  defp no_open_pr(snapshot, facts) do
    if Enum.any?(
         snapshot["change_requests"],
         &(&1["state"] == "open" and &1["source_branch"] == facts["head_branch"])
       ), do: {:error, :already_open}, else: :ok
  end

  def shape(facts) do
    if Foreman.Requests.LocalRefs.branch_name?(facts["head_branch"]) and
         Foreman.Requests.LocalRefs.branch_name?(facts["base_branch"]) and
         match?({:ok, _}, Foreman.Requests.LocalRefs.sha(facts["expected_sha"])) and
         Foreman.Requests.Decision.text?(facts["title"]) and
         byte_size(facts["title"]) <= 256 and is_binary(facts["body"]) and
         byte_size(facts["body"]) <= 65_536 and facts["base_ok"] in [nil, false, true],
       do: :ok,
       else: {:error, :invalid_facts}
  end

  @doc "A stack parent must be a recorded ticket blocker with an open PR. Epic membership is not a stack edge."
  def base_rule(repo, snapshot, facts, key) do
    branches = stack_bases(snapshot, facts["head_branch"], key)
    expected = Enum.uniq([Foreman.MergePolicy.base(repo, snapshot["default_branch"]) | branches])

    if facts["base_ok"] == true or facts["base_branch"] in expected do
      :ok
    else
      {:error,
       %{
         error: "base_unexpected",
         expected_bases: expected,
         message:
           "Use one of these base branches: #{Enum.join(expected, ", ")}. Use --base-ok to approve a different base."
       }}
    end
  end

  @doc "Open PR heads belonging to recorded blockers, excluding the child's own head."
  def stack_bases(snapshot, head, key) do
    parents = stack_parents(key)

    for pr <- snapshot["change_requests"] || [],
        pr["state"] == "open",
        pr["source_branch"] != head,
        Enum.any?(
          Foreman.Forge.Stack.links(pr, ticket_prefix(key)),
          &(&1["bead_id"] in parents)
        ),
        do: pr["source_branch"]
  end

  defp ticket_prefix({_, id}), do: id |> String.split("-", parts: 2) |> hd()
  defp ticket_prefix(nil), do: ""

  defp stack_parents(nil), do: []

  defp stack_parents({key, id}) do
    import Ecto.Query

    raw =
      Foreman.Repo.one(
        from b in "beads", where: b.repo_key == ^key and b.bead_id == ^id, select: b.raw
      ) || %{}

    for edge <- raw["dependencies"] || [], edge["type"] == "blocks", do: edge["depends_on_id"]
  end

  def guards(facts, adapter, opts, repo \\ nil, key \\ nil) do
    with :ok <- capable(adapter),
         {:ok, snapshot} <- adapter.list(facts["remote"], opts),
         :ok <- if(repo, do: base_rule(repo, snapshot, facts, key), else: :ok),
         {:ok, _} <- branch(adapter, facts, "base_branch", :base_missing, opts),
         :ok <- no_open_pr(snapshot, facts),
         :ok <- unchanged(facts, adapter, opts) do
      :ok
    end
  end

  def capable(adapter) do
    caps = adapter.capabilities()

    if caps.write and Map.get(caps, :create_change_request, false),
      do: :ok,
      else: {:error, :read_only}
  end

  def unchanged(facts, adapter, opts) do
    with {:ok, sha} <- branch(adapter, facts, "head_branch", :head_missing, opts) do
      if sha == facts["expected_sha"], do: :ok, else: {:error, :head_moved}
    end
  end

  defp branch(adapter, facts, key, missing, opts) do
    case adapter.branch_sha(facts["remote"], facts[key], opts) do
      {:error, :not_found} -> {:error, missing}
      result -> result
    end
  end

  @impl true
  def enqueue(request) do
    %{request_id: request.id} |> Foreman.Requests.OpenPrJob.new() |> Oban.insert!()
    :ok
  end
end
