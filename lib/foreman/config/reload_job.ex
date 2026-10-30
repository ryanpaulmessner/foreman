defmodule Foreman.Config.ReloadJob do
  @moduledoc """
  Serializes config installation and last-good retention in Postgres.

  A single worker-local input cache is paired with the freshly read database snapshot.
  It is only a read-skipping hint: a cold worker prepares again without rewriting an
  unchanged snapshot. Discovery always runs so new and removed repositories are found.
  """
  use Oban.Worker,
    queue: :external_reads,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  require Logger
  alias Foreman.Config.{Fingerprint, Reload}
  alias Foreman.Repo

  def enqueue, do: new(%{}) |> Oban.insert()

  @impl true
  def perform(_job) do
    {elapsed, result} = :timer.tc(fn -> reload() end)

    if elapsed > 1_000_000 do
      Logger.info("Config reload took #{div(elapsed, 1000)} ms")
    end

    result
  end

  defp reload do
    directory = Application.fetch_env!(:foreman, :config_directory)
    previous = Foreman.RuntimeState.config()
    discovered = discover(Application.get_env(:foreman, :discovery_root, Path.expand("~/dev")))
    fingerprint = Fingerprint.read(directory, discovered, previous && previous.config)

    if reusable?(previous, fingerprint) do
      :ok
    else
      prepare(directory, discovered, previous)
    end
  end

  defp reusable?(nil, _), do: false

  defp reusable?(previous, fingerprint) do
    is_nil(previous.error) &&
      :persistent_term.get({__MODULE__, :inputs}, nil) == {snapshot(previous), fingerprint} &&
      Enum.all?(previous.stores, fn {_, store} ->
        not String.starts_with?(store["identity"], "unreachable:")
      end)
  end

  defp prepare(directory, discovered, previous) do
    {:ok, defaults} =
      Foreman.Config.parse_layers([
        {"defaults", File.read!(Application.app_dir(:foreman, "priv/foreman.defaults.toml"))}
      ])

    initial = Reload.new(if(previous, do: previous.config, else: defaults))
    {loading, [read: {:config, generation}]} = Reload.request(initial)
    result = Foreman.Config.load(directory)
    {completed, effects} = Reload.complete(loading, generation, result)
    fingerprint = Fingerprint.read(directory, discovered, completed.config)
    confirmed_result = Foreman.Config.load(directory)

    row = %{
      id: 1,
      config: completed.config,
      error: completed.error,
      source: directory,
      discovered: discovered,
      stores: Map.new(completed.config["repos"], fn repo -> {repo["key"], store(repo)} end),
      loaded_at: if(completed.error && previous, do: previous.loaded_at, else: DateTime.utc_now())
    }

    outcome =
      cond do
        confirmed_result != result ||
            Fingerprint.read(directory, discovered, completed.config) != fingerprint ->
          :retry

        same_snapshot?(previous, row) ->
          :unchanged

        true ->
          {:ok, outcome} =
            Repo.transaction(fn ->
              case Repo.query!("SELECT pg_try_advisory_xact_lock(83467219)").rows do
                [[true]] -> install(previous, row)
                [[false]] -> :retry
              end
            end)

          outcome
      end

    case outcome do
      :retry ->
        {:snooze, 1}

      installed ->
        if installed == :changed do
          Enum.each(effects, fn {:broadcast, :config} ->
            Foreman.Events.broadcast(:config_changed, "config")
          end)
        end

        :persistent_term.put({__MODULE__, :inputs}, {snapshot(row), fingerprint})
        :ok
    end
  end

  defp install(previous, row) do
    current = Foreman.RuntimeState.config()

    cond do
      current != previous ->
        :retry

      same_snapshot?(current, row) ->
        :unchanged

      true ->
        Repo.insert_all("board_config", [row],
          on_conflict: {:replace, Map.keys(row) -- [:id]},
          conflict_target: [:id]
        )

        :changed
    end
  end

  defp same_snapshot?(nil, _), do: false

  defp same_snapshot?(previous, row), do: snapshot(previous) == snapshot(row)

  defp snapshot(row), do: Map.take(row, [:config, :error, :source, :discovered, :stores])

  defp store(%{"tickets" => "files"} = repo) do
    case Foreman.TicketFiles.main_checkout(repo["path"]) do
      {:ok, root} -> %{"identity" => "files:" <> root, "path" => root, "mode" => "files"}
      _ -> %{"identity" => "unreachable:" <> repo["key"], "mode" => "files"}
    end
  end

  defp store(repo) do
    case Foreman.Beads.Store.resolve(repo["path"]) do
      {:ok, physical, identity} ->
        %{"identity" => identity, "path" => physical, "mode" => "embedded"}

      {:error, :server_mode} ->
        %{"identity" => "unreachable:" <> repo["key"], "mode" => "server mode"}

      _ ->
        %{"identity" => "unreachable:" <> repo["key"], "mode" => "unknown"}
    end
  end

  @doc "Read-only discovery, bounded to eight levels and excluding generated dependency trees."
  def discover(root) do
    {elapsed, repos} = :timer.tc(fn -> walk(root, 0) |> Enum.sort() end)

    :telemetry.execute([:foreman, :config, :discovery], %{duration: elapsed}, %{
      count: length(repos)
    })

    repos
  end

  defp walk(_, depth) when depth > 8, do: []

  defp walk(path, depth) do
    with {:ok, entries} <- File.ls(path),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(path) do
      found =
        if ".beads" in entries && File.dir?(Path.join(path, ".beads")), do: [path], else: []

      children =
        entries
        |> Enum.reject(
          &(&1 in ~w(.beads .git node_modules deps _build .cache vendor .venv dist coverage))
        )
        |> Enum.flat_map(&walk(Path.join(path, &1), depth + 1))

      found ++ children
    else
      _ -> []
    end
  end
end
