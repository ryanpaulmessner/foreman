defmodule Foreman.Week.HistoryJob do
  @moduledoc "Ten-minute worker for merged PR history and remote-ref containment."
  use Oban.Worker,
    queue: :external_reads,
    max_attempts: 1,
    unique: [period: 600, fields: [:worker, :args], states: :all]

  import Ecto.Query
  require Logger
  alias Foreman.{Repo, RuntimeState}
  alias Foreman.Week.{PrLinks, Containment}
  alias Foreman.Forge.ReadLifecycle

  def enqueue(key), do: new(%{key: key}) |> Oban.insert()

  @impl true
  def perform(%Oban.Job{args: args}) when map_size(args) == 0 do
    config = RuntimeState.config()
    keys = if config, do: get_in(config.config, ["board", "week_repos"]) || ["work"], else: []
    Enum.each(keys, &enqueue/1)
    :ok
  end

  def perform(%Oban.Job{args: %{"key" => key}}) do
    config = RuntimeState.config()
    keys = if config, do: get_in(config.config, ["board", "week_repos"]) || ["work"], else: []
    repo = Foreman.Forge.SyncJob.configured(key)

    if key in keys and not is_nil(repo) and is_binary(repo["code_path"]) do
      refresh(
        key,
        repo["github"],
        repo["code_path"],
        &Foreman.Week.MergedPrs.list/3,
        Keyword.put(Foreman.Forge.options(), :configured, repo)
      )
    else
      :ok
    end
  end

  def refresh(key, remote, path, reader, opts) do
    backfilled =
      Repo.exists?(
        from b in "week_pr_backfills", where: b.repo_key == ^key and b.remote == ^remote
      )

    history = read(fn -> reader.(remote, if(backfilled, do: 21, else: 60), opts) end)
    fetch = read(fn -> Containment.fetch(path) end)

    if fetch != :ok,
      do: Logger.warning("Week containment fetch failed for #{key}; keeping cached results")

    # Check both persisted heads and newly read heads without holding a DB lock.
    incoming =
      case history do
        {:ok, prs} -> Enum.map(prs, &%{number: &1["number"], head_sha: &1["head_sha"]})
        _ -> []
      end

    results =
      if fetch == :ok do
        (PrLinks.list(key, remote) ++ incoming)
        |> Enum.uniq_by(&{&1.number, &1.head_sha})
        |> Enum.flat_map(fn pr ->
          case Containment.check(path, pr.head_sha) do
            {:ok, result} -> [{pr, result}]
            {:error, _} -> []
          end
        end)
      else
        []
      end

    Repo.transaction(fn ->
      Repo.query!("SELECT id FROM board_config WHERE id = 1 FOR SHARE")
      expected = Keyword.get(opts, :configured)

      if is_nil(expected) or Foreman.Forge.SyncJob.configured(key) == expected do
        case history do
          {:ok, prs} ->
            PrLinks.record(key, remote, prs)

            Repo.insert_all(
              "week_pr_backfills",
              [%{repo_key: key, remote: remote, completed_at: DateTime.utc_now()}],
              on_conflict: :nothing
            )

          {:error, reason} ->
            Logger.warning("Week PR history read failed for #{key}: #{inspect(reason)}")
        end

        Enum.each(results, fn {pr, result} ->
          Repo.update_all(
            from(p in "week_pr_links",
              where:
                p.repo_key == ^key and
                  p.remote == ^remote and p.number == ^pr.number and
                  p.head_sha == ^pr.head_sha
            ),
            set: [
              in_production: result.in_production,
              in_staging: result.in_staging,
              checked_at: DateTime.utc_now()
            ]
          )
        end)
      end
    end)

    :ok
  end

  # Oban owns cadence and retries; each read uses the shared publish/retain machine.
  defp read(effect) do
    {:reading, [fetch: :snapshot]} =
      ReadLifecycle.step(:idle, :start, %{elapsed: 600, manual: false, rate_limited: false})

    case effect.() do
      {:error, _} = error ->
        {:failed, [retain: :snapshot]} = ReadLifecycle.step(:reading, :failed, %{})
        error

      result ->
        {:fresh, [publish: :snapshot]} = ReadLifecycle.step(:reading, :succeeded, %{})
        result
    end
  end
end
