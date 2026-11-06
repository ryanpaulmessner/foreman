defmodule ForemanWeb.SessionGrid do
  @moduledoc "Coordinator groups projected from the same filtered rows as the Tree."
  use ForemanWeb, :html

  attr :item, :map, required: true
  attr :connection, :atom, required: true

  def card(assigns) do
    assigns =
      assign(
        assigns,
        :dead,
        not is_nil(assigns.item.row.ended_at) or assigns.item.row.state in ["ended", "parked"]
      )

    ~H"""
    <article
      id={"grid-card-#{@item.id}"}
      data-grid-live={if !@dead, do: @item.id}
      data-color={@item.view.color}
      class={["bb-grid-card", @dead && "bb-grid-ended"]}
    >
      <.link
        id={"grid-link-#{@item.id}"}
        navigate={~p"/sessions/#{@item.id}"}
        class="bb-session-row-link"
        aria-label={"Open #{@item.row.name}"}
      >
        <span class="sr-only">Open {@item.row.name}</span>
      </.link>
      <div class="flex items-center gap-2 min-w-0">
        <strong class="font-mono text-xs truncate" title={@item.row.name}>{@item.row.name}</strong>
        <span :if={@item.row.kind != "build"} class="bb-session-kind">
          {if @item.row.kind == "main_coordinator", do: "main", else: "epic"}
        </span>
        <button
          :if={!@dead}
          id={"grid-focus-#{@item.id}"}
          class="bb-iconbtn bb-grid-focus"
          phx-click="focus"
          phx-value-id={@item.id}
          disabled={@connection == :tmux_error}
          title={if @connection == :tmux_error, do: "tmux does not answer", else: "Focus terminal"}
          aria-label={"Focus #{@item.row.name}"}
        >
          <.icon name="hero-command-line" class="size-4" />
        </button>
      </div>
      <ForemanWeb.SessionState.badge id={"grid-state-#{@item.id}"} view={@item.view} />
      <span :if={@dead} class="text-xs text-foreground-softer">The terminal is closed</span>
      <span :if={@dead and @item.children_live} class="text-xs text-foreground-softer">
        Its builds still run
      </span>
      <%= if !@dead do %>
        <div class="bb-grid-ticket text-xs truncate" title={@item.title}>
          <span :if={@item.row.ticket} class="font-mono">{@item.row.ticket}</span> {@item.title}
        </div>
        <div
          id={"grid-output-#{@item.id}"}
          phx-update="ignore"
          class="bb-term bb-grid-output"
          data-theme="dark"
        >
          <pre class="bb-term-body">Reading the terminal…</pre>
        </div>
      <% end %>
    </article>
    """
  end

  def observer(assigns) do
    ~H"""
    <div id="session-grid-observer" phx-hook=".SessionGrid" phx-update="ignore"></div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SessionGrid">
      export default {
        mounted() {
          this.ids = new Set()
          this.nodes = new Map()
          this.send = (event, payload) => {
            if (this.liveSocket.isConnected()) this.pushEvent(event, payload).catch(() => {})
          }
          this.report = () => {
            clearTimeout(this.pending)
            this.pending = setTimeout(() => this.visibility(), 40)
          }
          this.observer = new IntersectionObserver(entries => {
            for (const e of entries) {
              const id = e.target.dataset.gridLive
              if (e.isIntersecting) this.ids.add(id)
              else this.ids.delete(id)
            }
            this.report()
          })
          this.scan = () => {
            for (const [node, id] of this.nodes) {
              if (!node.isConnected || !node.dataset.gridLive) { this.observer.unobserve(node); this.nodes.delete(node); this.ids.delete(id) }
            }
            document.querySelectorAll("[data-grid-live]").forEach(node => {
              if (!this.nodes.has(node)) { this.nodes.set(node, node.dataset.gridLive); this.observer.observe(node) }
            })
            this.report()
          }
          this.mutations = new MutationObserver(this.scan)
          this.mutations.observe(document.getElementById("session-grid"), {childList: true, subtree: true, attributes: true, attributeFilter: ["hidden", "data-grid-live"]})
          this.visibility = () => this.send("grid_visibility", {ids: [...this.ids], visible: !document.hidden})
          document.addEventListener("visibilitychange", this.visibility)
          this.handleEvent("grid_output", ({id, html, empty}) => {
            const pre = document.getElementById(`grid-output-${id}`)?.querySelector("pre")
            if (pre) { if (empty) pre.textContent = "No output yet."; else pre.innerHTML = html; pre.dataset.ready = "true" }
          })
          this.handleEvent("save-sessions-view", ({view}) => { try { localStorage.setItem("foreman:sessions-view", view) } catch (_) {} })
          try {
            const view = localStorage.getItem("foreman:sessions-view")
            if (view === "grid" || view === "tree") this.send("restore-sessions-view", {view})
          } catch (_) {}
          this.scan()
        },
        disconnected() { clearTimeout(this.pending) },
        reconnected() { this.visibility(); this.scan() },
        destroyed() { clearTimeout(this.pending); this.observer.disconnect(); this.mutations.disconnect(); document.removeEventListener("visibilitychange", this.visibility) }
      }
    </script>
    """
  end

  def build(rows) do
    rows = Enum.reject(rows, & &1.group)
    coordinators = Enum.reject(rows, &(&1.row.kind == "build"))
    ids = MapSet.new(coordinators, & &1.id)

    groups =
      Enum.map(coordinators, fn coordinator ->
        children =
          Enum.filter(rows, &(&1.row.kind == "build" and &1.row.parent_id == coordinator.id))

        [
          header(coordinator.id, coordinator.row.name),
          coordinator | Enum.sort_by(children, &order/1)
        ]
      end)

    unassigned =
      Enum.filter(rows, &(&1.row.kind == "build" and not MapSet.member?(ids, &1.row.parent_id)))

    List.flatten(groups) ++
      if(unassigned == [],
        do: [],
        else: [header("unassigned", "Unassigned") | Enum.sort_by(unassigned, &order/1)]
      )
  end

  defp header(id, name), do: %{id: "group-" <> id, group: true, name: name}

  defp order(item) do
    rank =
      if item.row.ended_at,
        do: 5,
        else:
          Enum.find_index(
            ["Waiting on you", "Working", "In review", "Idle"],
            &(&1 == item.view.label)
          ) || 4

    {rank, item.row.name, item.id}
  end
end
