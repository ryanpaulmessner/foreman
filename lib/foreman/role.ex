defmodule Foreman.Role do
  @moduledoc """
  Static deployment roles for a single release; no Erlang clustering required.
  Both roles keep Repo and Oban's Postgres notifier. Only worker/all execute jobs.
  Future scheduler and watcher children belong in `worker_children/0`, not in
  the application's common child list.

  PREVIEW=1 keeps the endpoint and notifier but disables worker children and job
  execution, serving only the copied cache. FOREMAN_PREVIEW_READERS=1 restores
  the selected role's workers for reader development; external writes remain
  subject to Foreman.Preview's execution-time guard.
  """

  @roles %{
    "web" => %{endpoint: true, worker: false},
    "worker" => %{endpoint: false, worker: true},
    "all" => %{endpoint: true, worker: true}
  }

  def children(role, oban) do
    settings = Map.fetch!(@roles, role)
    worker? = settings.worker and preview_readers_enabled?()
    oban = Keyword.put(oban, :notifier, Oban.Notifiers.Postgres)

    oban =
      if worker?,
        do: oban,
        else: Keyword.merge(oban, queues: false, plugins: false, peer: false)

    [{Oban, oban}] ++
      if(worker?, do: worker_children(), else: []) ++
      if(settings.endpoint, do: [ForemanWeb.Endpoint], else: [])
  end

  def endpoint?(role), do: Map.fetch!(@roles, role).endpoint

  defp preview_readers_enabled? do
    System.get_env("PREVIEW") != "1" or System.get_env("FOREMAN_PREVIEW_READERS") == "1"
  end

  defp worker_children do
    if Application.get_env(:foreman, :runtime_enabled, true),
      do: [
        Foreman.Forge.Credentials,
        Foreman.Runtime,
        Foreman.Config.Watcher,
        Foreman.SpoolWorker,
        Foreman.SessionMonitor,
        Foreman.Previews.Poller,
        Foreman.OsNotifications
      ],
      else: []
  end
end
