defmodule Foreman.Merge.MergeJob do
  @moduledoc "One-shot guarded merge. Durable intent is committed before any forge IO."
  use Oban.Worker, queue: :external_writes, max_attempts: 1
  alias Foreman.Merge

  @impl true
  def timeout(_), do: :timer.seconds(60)
  @impl true
  def perform(%Oban.Job{args: %{"action_id" => id}}),
    do: run(id, Foreman.Forge.adapter())

  def run(id, adapter, opts \\ nil) do
    case Merge.claim(id, :merge) do
      nil -> :ok
      row -> execute(row, adapter, opts)
    end
  end

  defp execute(row, adapter, opts) do
    caps = adapter.capabilities()

    result =
      with :ok <- Foreman.Preview.allow_external_write(),
           opts = opts || Foreman.Forge.options(),
           true <- caps.write || {:error, :read_only},
           true <- Merge.configured?(row) || {:error, :config_changed},
           # Human-merge repos are merged by a person on GitHub: refuse before any forge IO.
           true <-
             not Foreman.MergePolicy.human_key?(row.repo_key) || {:error, :human_merge_policy},
           {:ok, snapshot} <- adapter.list(row.remote, Keyword.put(opts, :tracked, [row.number])),
           :ok <- Merge.validate(snapshot, row),
           :ok <- weak_guard(row, adapter, caps, opts),
           true <- Merge.configured?(row) || {:error, :config_changed},
           true <-
             not Foreman.MergePolicy.human_key?(row.repo_key) || {:error, :human_merge_policy} do
        adapter.merge(row.remote, row.number, row.head_sha, opts)
      end

    case result do
      {:ok, %{"sha" => sha}} -> Merge.advance(row, :merge_ok, caps, merge_sha: sha)
      {:error, reason} -> Merge.advance(row, :merge_failed, caps, error: to_string(reason))
    end
  rescue
    _ -> Merge.advance(row, :merge_failed, adapter.capabilities(), error: "outcome_unknown")
  end

  defp weak_guard(_, _, %{head_guard: true}, _), do: :ok

  defp weak_guard(row, adapter, _, opts) do
    with {:ok, snapshot} <- adapter.list(row.remote, Keyword.put(opts, :tracked, [row.number])),
         do: Merge.validate(snapshot, row)
  end
end
