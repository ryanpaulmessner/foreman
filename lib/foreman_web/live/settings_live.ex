defmodule ForemanWeb.SettingsLive do
  use ForemanWeb, :live_view
  alias Fluxon.Components.{Badge, Button}

  @impl true
  def mount(_, _, socket) do
    if connected?(socket) do
      Foreman.Events.subscribe()
      Process.send_after(self(), :reconcile, 3_000)
    end

    {:ok,
     socket
     |> stream_configure(:repos, dom_id: &("repo-" <> &1["key"]))
     |> refresh()}
  end

  @impl true
  def handle_event("reload", _, socket) do
    case Foreman.Config.ReloadJob.enqueue() do
      {:ok, _} -> {:noreply, put_flash(socket, :info, "Reload requested")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not request reload")}
    end
  end

  @impl true
  def handle_info(:reconcile, socket) do
    Process.send_after(self(), :reconcile, 3_000)
    {:noreply, refresh(socket)}
  end

  def handle_info({:notification, :foreman_events, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    snapshot = Foreman.RuntimeState.config()
    config = if snapshot, do: snapshot.config, else: %{"repos" => [], "columns" => []}
    paths = MapSet.new(config["repos"], & &1["path"])

    discovered =
      if snapshot, do: Enum.reject(snapshot.discovered, &MapSet.member?(paths, &1)), else: []

    repos = Foreman.RuntimeState.repos()

    socket
    |> assign(
      snapshot: snapshot,
      config: config,
      discovered: discovered,
      toml: toml(config),
      sidebar_repos: repos
    )
    |> stream(:repos, repos, reset: true)
  end

  defp home(path), do: String.replace_prefix(path, System.user_home!(), "~")
  defp age(nil), do: "never synced"
  defp age(%NaiveDateTime{} = time), do: age(DateTime.from_naive!(time, "Etc/UTC"))
  defp age(time), do: "snapshot · #{ForemanWeb.RelativeTime.format(time)}"

  defp health_label(%{state: "warning", file_error_count: count}),
    do: "#{count} file #{if count == 1, do: "error", else: "errors"}"

  defp health_label(health), do: health.state
  defp color("synced"), do: "success"
  defp color("unreachable"), do: "danger"
  defp color(_), do: "warning"
  defp quote_toml(value), do: Jason.encode!(value)

  defp repo_block(path),
    do: "[[repos]]\nkey = #{quote_toml(Path.basename(path))}\npath = #{quote_toml(home(path))}\n"

  defp toml(config) do
    columns =
      Enum.map_join(config["columns"], "\n", fn c ->
        "[[columns]]\ntitle = #{quote_toml(c["title"])}\nstages = #{quote_toml(c["stages"])}\n"
      end)

    repos =
      Enum.map_join(config["repos"], "\n", fn r ->
        "[[repos]]\nkey = #{quote_toml(r["key"])}\npath = #{quote_toml(home(r["path"]))}\nenabled = #{r["enabled"]}\ntickets = #{quote_toml(r["tickets"] || "beads")}\n"
      end)

    columns <> "\n" <> repos
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      drawer_state={@drawer_state}
      streams={@streams}
      flash={@flash}
      pending_count={@pending_count}
      active={:settings}
      repos={@sidebar_repos}
    >
      <header class="flex flex-wrap items-center gap-3">
        <div class="mr-auto space-y-1">
          <h1 class="text-[22px] font-semibold text-foreground">Settings</h1>
        </div>
        <Button.button id="reload-config" phx-click="reload">
          <.icon name="hero-arrow-path" class="size-4" /> Reload
        </Button.button>
      </header>
      <section class="bb-panel flex flex-wrap items-center gap-6" id="config-status">
        <div class="min-w-0 grow space-y-2">
          <h2 class="bb-label">Config sources, merged in order</h2>
          <div class="flex flex-wrap items-center gap-2 text-xs">
            <Badge.badge>priv/foreman.defaults.toml</Badge.badge>
            <span class="text-foreground-softer">then</span>
            <Badge.badge>
              {if @snapshot,
                do: home(Path.join(@snapshot.source, "foreman.toml")),
                else: "Waiting for worker"}
            </Badge.badge>
            <span class="text-foreground-softer">then</span>
            <Badge.badge>foreman.local.toml (untracked)</Badge.badge>
          </div>
        </div>
        <div class="space-y-2">
          <h2 class="bb-label">Status</h2>
          <Badge.badge color={if @snapshot && !@snapshot.error, do: "success", else: "warning"}>
            {cond do
              !@snapshot -> "Waiting for worker"
              @snapshot.error -> "Invalid edit, last good config in use"
              true -> "Valid · watching for changes"
            end}
          </Badge.badge>
          <p
            :if={@snapshot}
            class="text-xs text-foreground-softer"
            title={to_string(@snapshot.loaded_at)}
          >
            Loaded {Calendar.strftime(@snapshot.loaded_at, "%H:%M:%S")} UTC
          </p>
        </div>
      </section>
      <div
        :if={@snapshot && @snapshot.error}
        id="config-error"
        role="alert"
        class="rounded-lg border border-danger bg-danger-soft p-4 text-foreground-danger-soft"
      >
        {@snapshot.error} · last good config
      </div>
      <div class="flex flex-wrap items-start gap-5">
        <div class="min-w-0 flex-[999_1_560px] space-y-5">
          <section class="space-y-3">
            <h2 class="bb-label">Repos</h2>
            <div class="overflow-x-auto rounded-[10px] border border-base">
              <table class="bb-table">
                <thead>
                  <tr>
                    <th>Key</th>
                    <th>Path</th>
                    <th>GitHub</th>
                    <th>Ticket source</th>
                    <th>Read</th>
                    <th>Enabled</th>
                  </tr>
                </thead>
                <tbody id="repos" phx-update="stream">
                  <tr id="repos-empty" class="hidden only:table-row">
                    <td colspan="6">No repositories configured.</td>
                  </tr>
                  <tr :for={{id, repo} <- @streams.repos} id={id}>
                    <td class="font-medium">{repo["key"]}</td>
                    <td
                      class="max-w-[220px] overflow-hidden text-ellipsis font-mono text-xs"
                      title={home(repo["path"])}
                    >
                      {home(repo["path"])}
                    </td>
                    <td class="font-mono text-xs">{repo["github"] || "no remote"}</td>
                    <td class="text-xs">{repo["store_mode"]}</td>
                    <td>
                      <Badge.badge
                        data-health={repo["health"].state}
                        color={color(repo["health"].state)}
                      >
                        {if repo["enabled"], do: health_label(repo["health"]), else: "disabled"} · {repo[
                          "count"
                        ]}
                      </Badge.badge>
                      <div
                        :if={repo["health"].reason}
                        class={[
                          "mt-1 w-64 whitespace-normal break-words text-xs",
                          if(repo["health"].state == "warning",
                            do: "text-warning",
                            else: "text-danger"
                          )
                        ]}
                      >
                        {repo["health"].reason}
                      </div>
                      <div class="mt-1 text-xs text-foreground-softer">
                        {age(repo["health"].succeeded_at)}
                      </div>
                    </td>
                    <td>
                      <.input
                        type="checkbox"
                        name={"enabled-#{repo["key"]}"}
                        id={"enabled-#{repo["key"]}"}
                        checked={repo["enabled"]}
                        disabled
                        class="bb-switch"
                        aria-label={"#{repo["key"]} enabled (read only)"}
                      />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
          <section class="space-y-3" id="foreman-columns">
            <h2 class="bb-label">Foreman columns · from [[columns]]</h2>
            <div class="grid grid-cols-[repeat(auto-fit,minmax(145px,1fr))] gap-2.5">
              <div :for={column <- @config["columns"]} class="bb-panel space-y-2 !p-3">
                <b>{column["title"]}</b>
                <div class="flex flex-wrap gap-1">
                  <Badge.badge :for={stage <- column["stages"]}>{stage}</Badge.badge>
                </div>
                <span :if={column["collapsed"]} class="text-xs text-foreground-softer">
                  collapsed
                </span>
              </div>
            </div>

            <div class="bb-panel space-y-2 !bg-sunken">
              <h3 class="bb-label">Epic stages · fixed, not configurable</h3>
              <div class="flex flex-wrap gap-1">
                <Badge.badge :for={
                  stage <-
                    ~w(idea speccing spec_approved ticketed building shipping shipped done abandoned)
                }>
                  {stage}
                </Badge.badge>
              </div>
            </div>
          </section>
          <section class="space-y-3" id="discovered-repos">
            <h2 class="bb-label">Found under ~/dev, not in config</h2>
            <div class="bb-panel space-y-3">
              <p :if={@discovered == []} class="text-foreground-softer">
                No unconfigured repositories found.
              </p>
              <div :for={path <- @discovered}>
                <p class="mb-2 text-xs">foreman.toml · {home(path)}</p>
                <pre class="overflow-x-auto rounded-lg bg-sunken p-3 text-xs">{repo_block(path)}</pre>
              </div>
            </div>
          </section>
        </div>
        <aside class="min-w-0 flex-[1_1_320px] space-y-3">
          <h2 class="bb-label">Loaded columns & repos · read-only view</h2>
          <pre
            id="config-preview"
            class="whitespace-pre-wrap [overflow-wrap:anywhere] rounded-[10px] border border-base bg-sunken p-4 font-mono text-xs leading-[19px]"
          >{@toml}</pre>
        </aside>
      </div>
    </Layouts.app>
    """
  end
end
