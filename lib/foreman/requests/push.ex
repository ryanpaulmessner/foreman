defmodule Foreman.Requests.Push do
  @moduledoc "Push facts and guards. PR updates bind the old head; the job checks ancestry and uses an exact lease."
  @behaviour Foreman.Requests.Kind
  import Ecto.Query
  alias Foreman.{Repo, RuntimeState}
  alias Foreman.Requests.LocalRefs

  @impl true
  def validate(_, %{stage: stage}) when stage not in [:committed, :pr_open],
    do: {:error, :not_committed}

  def validate(facts, row) when is_map(facts) do
    with {:ok, repo} <- configured(row.repo_key),
         :ok <- shape(facts),
         :ok <- LocalRefs.same_repo(facts["worktree"], Foreman.CodeCheckout.path(repo)),
         :ok <- unchanged(facts),
         %{remote: remote, snapshot: snapshot} <- Foreman.Forge.Store.get(row.repo_key),
         true <- remote == repo["github"] || {:error, :config_changed},
         :ok <- default_rule(facts, row, snapshot["default_branch"]),
         :ok <- human_rule(facts, repo, snapshot["default_branch"]),
         :ok <- Foreman.Requests.TryItGate.validate(facts, row, repo, snapshot),
         :ok <- update_rule(facts, snapshot, row.stage) do
      {:ok,
       facts
       |> Map.take(
         ~w(worktree local_branch expected_sha remote_branch expected_old_head force_with_lease no_try_it)
       )
       |> Map.put("remote", remote)}
    else
      nil -> {:error, :default_branch_unknown}
      error -> error
    end
  end

  def validate(_, _), do: {:error, :invalid_facts}

  def update_rule(facts, snapshot, stage) do
    pr =
      Enum.find(
        snapshot["change_requests"] || [],
        &(&1["state"] == "open" and &1["source_branch"] == facts["remote_branch"])
      )

    old = facts["expected_old_head"]

    cond do
      facts["force_with_lease"] not in [nil, false, true] ->
        {:error, :invalid_facts}

      (pr || facts["force_with_lease"] == true) && not match?({:ok, _}, LocalRefs.sha(old)) ->
        {:error, :expected_old_head_required}

      pr && pr["head_sha"] != old ->
        {:error, :head_moved}

      stage == :pr_open && is_nil(pr) ->
        {:error, :open_pr_required}

      not is_nil(old) && not match?({:ok, _}, LocalRefs.sha(old)) ->
        {:error, :invalid_facts}

      true ->
        :ok
    end
  end

  def configured(key) do
    case Enum.find(RuntimeState.repos(), &(&1["key"] == key)) do
      %{"forge" => "github", "github" => remote, "enabled" => true} = repo
      when is_binary(remote) ->
        if Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, remote),
          do: {:ok, repo},
          else: {:error, :forge_disabled}

      _ ->
        {:error, :forge_disabled}
    end
  end

  def shape(facts) do
    if LocalRefs.branch_name?(facts["local_branch"]) and
         LocalRefs.branch_name?(facts["remote_branch"]) and
         match?({:ok, _}, LocalRefs.sha(facts["expected_sha"])) and is_binary(facts["worktree"]) and
         (not Map.has_key?(facts, "no_try_it") or
            Foreman.Requests.Decision.text?(facts["no_try_it"])),
       do: :ok,
       else: {:error, :invalid_facts}
  end

  def unchanged(facts) do
    expected = facts["expected_sha"]

    case LocalRefs.branch(facts["worktree"], facts["local_branch"]) do
      {:ok, ^expected} -> :ok
      _ -> {:error, :local_sha_changed}
    end
  end

  def default_rule(facts, row, default) when is_binary(default) and default != "" do
    if facts["remote_branch"] == default and parent?(row),
      do: {:error, :epic_default_branch},
      else: :ok
  end

  def default_rule(_, _, _), do: {:error, :default_branch_unknown}

  @doc """
  Human-merge repos reach shared branches only through a PR a person merges: no push to the
  PR base or the default branch, for any ticket (one-off tickets included).
  """
  def human_rule(facts, repo, default) do
    if Foreman.MergePolicy.human?(repo) and
         facts["remote_branch"] in Foreman.MergePolicy.protected_branches(repo, default),
       do: {:error, :human_merge_base_branch},
       else: :ok
  end

  defp parent?(row) do
    linked =
      Repo.exists?(
        from l in "epic_links", where: l.repo_key == ^row.repo_key and l.bead_id == ^row.bead_id
      )

    raw =
      Repo.one(
        from b in "beads",
          where: b.repo_key == ^row.repo_key and b.bead_id == ^row.bead_id,
          select: b.raw
      )

    row.machine == Foreman.Epic or linked or
      Enum.any?((raw || %{})["dependencies"] || [], &(&1["type"] == "parent-child"))
  end

  @impl true
  def enqueue(request) do
    %{request_id: request.id} |> Foreman.Requests.PushJob.new() |> Oban.insert!()
    :ok
  end
end
