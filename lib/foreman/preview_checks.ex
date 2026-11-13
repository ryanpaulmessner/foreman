defmodule Foreman.PreviewChecks do
  @moduledoc "Checks local preview reachability without advancing the Request machine."
  import Ecto.Query
  alias Foreman.{Repo, Requests, PreviewCheck}
  alias Foreman.Requests.Request

  def run do
    Repo.all(
      from r in Request,
        where:
          r.kind == "review_ui" and r.state == "pending" and
            fragment("?->>'url' IS NOT NULL", r.facts)
    )
    |> Task.async_stream(&check(&1.id), max_concurrency: 8, timeout: :infinity)
    |> Stream.run()
  end

  def check(id, opts \\ []) do
    case Requests.get(id) do
      %{kind: "review_ui", state: "pending", facts: %{"url" => url}} = request ->
        event = if reachable?(url, opts), do: :check_ok, else: :check_failed
        persist(request, event)

      _ ->
        :ok
    end
  end

  defp reachable?(url, opts) do
    if Foreman.TryIt.local_url?(url) do
      case Req.get(
             url,
             Keyword.merge(opts,
               redirect: false,
               retry: false,
               receive_timeout: 2_000,
               pool_timeout: 2_000,
               connect_options: [timeout: 2_000],
               into: fn {:data, _}, acc -> {:halt, acc} end
             )
           ) do
        {:ok, %{status: status}} -> status in 200..399
        _ -> false
      end
    else
      false
    end
  end

  defp persist(before, event) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "foreman:overlay:" <> before.repo_key
      ])

      request = Requests.get(before.id)

      if request && request.state == "pending" && request.facts["url"] == before.facts["url"] do
        {next, []} = PreviewCheck.step(PreviewCheck.load(request.facts), event, %{})

        if to_string(next) != request.facts["preview"] do
          request
          |> Ecto.Changeset.change(facts: Map.put(request.facts, "preview", to_string(next)))
          |> Repo.update!()

          Foreman.Events.broadcast(:requests_changed, request.id)
        end
      end
    end)
  end
end
