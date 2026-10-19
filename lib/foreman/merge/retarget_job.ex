defmodule Foreman.Merge.RetargetJob do
  @moduledoc "Retarget the confirmed child only. A failed follow-up never repeats the merge."
  use Oban.Worker, queue: :external_writes, max_attempts: 1
  alias Foreman.Merge
  @impl true
  def timeout(_), do: :timer.seconds(60)
  @impl true
  def perform(%Oban.Job{args: %{"action_id" => id}}),
    do: run(id, Foreman.Forge.adapter())

  def run(id, adapter, opts \\ nil) do
    case Merge.claim(id, :retarget) do
      nil -> :ok
      row -> execute(row, adapter, opts)
    end
  end

  defp execute(row, adapter, opts) do
    caps = adapter.capabilities()
    child = row.facts["child"]

    result =
      with :ok <- Foreman.Preview.allow_external_write(),
           opts = opts || Foreman.Forge.options(),
           true <- (caps.write && caps.retarget) || {:error, :manual_retarget},
           true <- Merge.configured?(row) || {:error, :config_changed},
           # Human-merge repos: a person retargets children on GitHub.
           true <-
             not Foreman.MergePolicy.human_key?(row.repo_key) || {:error, :human_merge_policy},
           {:ok, snapshot} <-
             adapter.list(row.remote, Keyword.put(opts, :tracked, [child["number"]])),
           :ok <- child_safe(snapshot, row),
           true <- Merge.configured?(row) || {:error, :config_changed} do
        adapter.retarget(row.remote, child["number"], row.facts["default_branch"], opts)
      end

    case result do
      :ok -> Merge.advance(row, :retarget_ok, caps)
      {:error, reason} -> Merge.advance(row, :retarget_failed, caps, error: to_string(reason))
    end
  rescue
    _ -> Merge.advance(row, :retarget_failed, adapter.capabilities(), error: "outcome_unknown")
  end

  defp child_safe(snapshot, row) do
    child =
      Enum.find(snapshot["change_requests"], &(&1["number"] == row.facts["child"]["number"]))

    if child && child["state"] == "open" &&
         child["source_branch"] == row.facts["child"]["source_branch"] &&
         child["target_branch"] in [row.facts["pr"]["source_branch"], row.facts["default_branch"]] &&
         snapshot["default_branch"] == row.facts["default_branch"],
       do: :ok,
       else: {:error, :child_changed}
  end
end
