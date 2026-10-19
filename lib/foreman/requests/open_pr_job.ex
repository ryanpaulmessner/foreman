defmodule Foreman.Requests.OpenPrJob do
  @moduledoc "One-shot PR creation. An ambiguous attempt must be observed, never replayed."
  use Oban.Worker, queue: :external_writes, max_attempts: 1
  @impl true
  def timeout(_), do: :timer.seconds(60)
  @impl true
  def perform(%Oban.Job{args: %{"request_id" => id}}), do: run(id)
  alias Foreman.{Requests, Overlay}
  alias Foreman.Requests.{OpenPr, Push}

  def run(id) do
    case Requests.get(id) do
      %{kind: "open_pr"} -> claim(id)
      _ -> :ok
    end
  end

  defp claim(id) do
    case Requests.resolve(id, :start, %{}) do
      {:ok, %{state: "executing"} = request} ->
        execute(request)

      _ ->
        Requests.resolve(id, :orphaned, %{})
        :ok
    end
  end

  defp execute(request) do
    facts = request.facts
    adapter = Foreman.Forge.adapter()

    result =
      with :ok <- Foreman.Preview.allow_external_write(),
           opts = Foreman.Forge.options(),
           {:ok, repo} <- Push.configured(request.repo_key),
           true <- repo["github"] == facts["remote"] || {:error, :config_changed},
           :ok <- OpenPr.shape(facts),
           :ok <- OpenPr.guards(facts, adapter, opts, repo),
           {:ok, current} <- Push.configured(request.repo_key),
           true <- current == repo || {:error, :config_changed},
           %{stage: :committed} <- Overlay.get({request.repo_key, request.bead_id}) do
        adapter.create_change_request(facts["remote"], facts, opts)
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :not_committed}
      end

    case result do
      {:ok, result} -> Requests.resolve(request.id, :succeeded, %{"result" => result})
      {:error, reason} -> Requests.resolve(request.id, :failed, %{"reason" => to_string(reason)})
    end

    :ok
  rescue
    _ ->
      Requests.resolve(request.id, :failed, %{"reason" => "outcome unknown"})
      :ok
  end
end
