defmodule Foreman.Merge do
  @moduledoc "Merge policy and durable intent. Confirmed facts are immutable; jobs revalidate before writing."
  import Ecto.Query
  alias Foreman.Repo
  alias Foreman.Merge.{Action, Record, MergeJob, RetargetJob}

  def prepare(snapshot, number) do
    prs = snapshot["change_requests"] || []
    pr = Enum.find(prs, &(&1["number"] == number))
    default = snapshot["default_branch"]

    children =
      if pr,
        do:
          Enum.filter(prs, &(&1["state"] == "open" && &1["target_branch"] == pr["source_branch"])),
        else: []

    cond do
      is_nil(pr) -> {:error, :not_found}
      pr["state"] != "open" -> {:error, :not_open}
      not is_binary(default) or pr["target_branch"] != default -> {:error, :not_bottom}
      pr["draft"] != false -> {:error, :draft}
      pr["checks"] not in ["success", "none"] -> {:error, :checks}
      pr["mergeable"] != "mergeable" -> {:error, :not_mergeable}
      not is_binary(pr["head_sha"]) or pr["head_sha"] == "" -> {:error, :head_unknown}
      length(children) > 1 -> {:error, :multiple_children}
      true -> {:ok, %{"pr" => pr, "default_branch" => default, "child" => List.first(children)}}
    end
  end

  def data(facts, capabilities) do
    %{
      eligible: true,
      head_unchanged: true,
      child: get_in(facts, ["child", "number"]),
      capabilities: capabilities
    }
  end

  def enqueue(key, remote, facts) do
    caps = Foreman.Forge.adapter().capabilities()
    human? = Foreman.MergePolicy.human_key?(key)

    case Action.step(:confirming, :confirm, data(facts, caps)) do
      _ when human? ->
        {:error, :human_merge_policy}

      {:merging, _} ->
        Repo.transaction(fn ->
          now = DateTime.utc_now()

          attrs = %{
            repo_key: key,
            remote: remote,
            number: facts["pr"]["number"],
            head_sha: facts["pr"]["head_sha"],
            requested_by: "local_ui",
            facts: facts,
            state: "merging",
            inserted_at: now,
            updated_at: now
          }

          {count, _} =
            Repo.insert_all(Record, [attrs],
              on_conflict: :nothing,
              conflict_target: [:remote, :number, :head_sha]
            )

          row =
            Repo.one!(
              from a in Record,
                where:
                  a.remote == ^remote and a.number == ^attrs.number and
                    a.head_sha == ^attrs.head_sha
            )

          if count == 1, do: %{action_id: row.id} |> MergeJob.new() |> Oban.insert!()
          row
        end)

      _ ->
        {:error, :read_only}
    end
  end

  def get(id), do: Repo.get(Record, id)

  def attempt(remote, number, head_sha),
    do:
      Repo.one(
        from a in Record,
          where: a.remote == ^remote and a.number == ^number and a.head_sha == ^head_sha
      )
      |> reconcile()

  def latest(key),
    do:
      Repo.one(from a in Record, where: a.repo_key == ^key, order_by: [desc: a.id], limit: 1)
      |> reconcile()

  def reconcile(%{state: state} = row) when state in ["merging", "retargeting"] do
    worker =
      if state == "merging", do: "Foreman.Merge.MergeJob", else: "Foreman.Merge.RetargetJob"

    id = to_string(row.id)

    terminal =
      Repo.exists?(
        from j in Oban.Job,
          where:
            j.worker == ^worker and fragment("?->>'action_id' = ?", j.args, ^id) and
              j.state in ["discarded", "cancelled", "completed"]
      )

    claimed_at = if state == "merging", do: row.claimed_at, else: row.retarget_claimed_at
    expired = claimed_at && DateTime.diff(DateTime.utc_now(), claimed_at) >= 90

    if terminal || expired do
      advance(row, :job_timeout, Foreman.Forge.adapter().capabilities(), error: "outcome_unknown")
      get(row.id)
    else
      row
    end
  end

  def reconcile(row), do: row

  # A committed compare-and-set precedes IO. Replayed jobs never resend a write,
  # even after a worker crash or an ambiguous transport result.
  def claim(id, phase) when phase in [:merge, :retarget] do
    {state, field} =
      if phase == :merge,
        do: {"merging", :claimed_at},
        else: {"retargeting", :retarget_claimed_at}

    {count, _} =
      Repo.update_all(
        from(a in Record, where: a.id == ^id and a.state == ^state and is_nil(field(a, ^field))),
        set: [{field, DateTime.utc_now()}]
      )

    if count == 1, do: get(id)
  end

  def advance(row, event, caps, attrs \\ []) do
    state = Enum.find(Action.__fsm__(:states), &(Atom.to_string(&1) == row.state))
    {next, effects} = Action.step(state, event, data(row.facts, caps))

    Repo.transaction(fn ->
      updates = [state: Atom.to_string(next), updated_at: DateTime.utc_now()] ++ attrs

      updates =
        if effects == [status: :manual_retarget] && !Keyword.has_key?(attrs, :error),
          do: Keyword.put(updates, :error, "manual_retarget"),
          else: updates

      {changed, _} =
        Repo.update_all(from(a in Record, where: a.id == ^row.id and a.state == ^row.state),
          set: updates
        )

      if changed == 1 do
        if effects == [enqueue: :retarget],
          do: %{action_id: row.id} |> RetargetJob.new() |> Oban.insert!()

        Foreman.Events.broadcast(:merge_changed, row.repo_key)
      end
    end)

    :ok
  end

  def configured?(row) do
    case Foreman.Forge.SyncJob.configured(row.repo_key) do
      %{"github" => remote} -> remote == row.remote
      _ -> false
    end
  end

  def validate(snapshot, row) do
    pr = Enum.find(snapshot["change_requests"] || [], &(&1["number"] == row.number))
    head_matches = is_nil(pr) || pr["head_sha"] == row.head_sha

    with true <- head_matches || {:error, :head_moved},
         {:ok, current} <- prepare(snapshot, row.number) do
      cond do
        current["default_branch"] != row.facts["default_branch"] ->
          {:error, :target_changed}

        current["pr"]["source_branch"] != row.facts["pr"]["source_branch"] ->
          {:error, :stack_changed}

        get_in(current, ["child", "number"]) != get_in(row.facts, ["child", "number"]) ->
          {:error, :stack_changed}

        true ->
          :ok
      end
    end
  end
end
