defmodule ForemanWeb.EpicLive do
  use ForemanWeb, :live_view
  alias Fluxon.Components.Badge

  def mount(_, _, socket) do
    if connected?(socket) do
      Foreman.Events.subscribe()
      Process.send_after(self(), :reconcile, 3_000)
    end

    {:ok, socket}
  end

  def handle_params(%{"repo" => repo, "id" => id} = params, uri, socket) do
    {:noreply,
     socket
     |> assign(epic_key: {repo, id})
     |> ForemanWeb.TicketDetail.load(params, uri)
     |> refresh()}
  end

  def handle_event("launch-session", params, socket),
    do: {:noreply, socket |> ForemanWeb.PlanningSession.launch(params) |> refresh()}

  def handle_event("preview", params, socket),
    do: {:noreply, ForemanWeb.TicketDetail.preview(socket, params)}

  def handle_event("close-ticket", params, socket),
    do: {:noreply, ForemanWeb.TicketDetail.close(socket, params)}

  def handle_event("epic-priority", params, socket) do
    key = socket.assigns.epic_priority && socket.assigns.epic_tracker_key
    {:noreply, socket |> ForemanWeb.TicketDetail.set_priority(key, params) |> refresh()}
  end

  def handle_event("ticket-priority", params, socket),
    do: {:noreply, socket |> ForemanWeb.TicketDetail.priority(params) |> refresh()}

  def handle_event("ticket-jump", params, socket),
    do: {:noreply, socket |> ForemanWeb.TicketDetail.jump(params) |> refresh()}

  def handle_info(:reconcile, socket) do
    Process.send_after(self(), :reconcile, 3_000)
    {:noreply, refresh(socket)}
  end

  def handle_info({:notification, :foreman_events, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    epic = Foreman.Drilldown.epic(socket.assigns.epic_key)

    socket
    |> ForemanWeb.TicketDetail.refresh()
    |> design_pack(epic)
    |> assign(
      epic: epic && summary(epic),
      epic_priority: epic && Map.get(Foreman.Priority.for_keys([epic.key]), epic.key),
      epic_tracker_key: epic && epic.key,
      planning_session: Foreman.Sessions.get(socket.assigns.epic_key),
      launchable: Foreman.Sessions.launchable?(epic),
      repos: Foreman.RuntimeState.repos()
    )
    |> stream(:columns, if(epic, do: epic.columns, else: []), reset: true)
    |> stream(:epic_history, if(epic, do: epic.history, else: []), reset: true)
    |> stream(:graph_nodes, if(epic, do: epic.graph.nodes, else: []), reset: true)
    |> stream(:graph_edges, if(epic, do: epic.graph.edges, else: []), reset: true)
  end

  defp design_pack(socket, epic) do
    repo_key = elem(socket.assigns.epic_key, 0)
    repo = Enum.find(Foreman.RuntimeState.repos(), &(&1["key"] == repo_key))
    path = epic && epic.design_link

    result = if repo && path, do: Foreman.Documents.open(repo, path)

    if socket.assigns[:design_document] == {repo_key, result} do
      socket
    else
      html =
        case result do
          {:ok, doc} -> Foreman.Markdown.render(doc.content, repo: repo_key, path: doc.path)
          nil -> ""
          _ -> "<p>Design file unavailable.</p>"
        end

      assign(socket, design_document: {repo_key, result}, design_html: html)
    end
  end

  defp summary(epic) do
    epic
    |> Map.take([:title, :stage, :status, :spec_link, :design_link, :total, :closed])
    |> Map.merge(%{
      planned_count: length(epic.planned),
      fallout_count: length(epic.fallout),
      column_count: length(epic.columns),
      graph: Map.take(epic.graph, [:width, :height])
    })
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      drawer_state={@drawer_state}
      drawer_error={@drawer_error}
      streams={@streams}
      flash={@flash}
      pending_count={@pending_count}
      active={:epic}
      repos={@repos}
    >
      <nav class="flex gap-2 text-xs text-foreground-softer" aria-label="Breadcrumb">
        <.link id="epic-back" navigate={home_path(@page_uri)}>Initiatives</.link><span>/</span><span>{elem(@epic_key, 0)}</span><span>/</span><span class="font-mono">{elem(@epic_key, 1)}</span>
      </nav>
      <%= if @epic do %>
        <header class="flex flex-wrap items-end justify-between gap-5">
          <div class="min-w-0 flex-1 space-y-3">
            <div class="flex gap-2">
              <Badge.badge color="info">{@epic.stage}</Badge.badge>
              <Badge.badge>epic</Badge.badge>
              <Badge.badge>bd: {@epic.status}</Badge.badge>
              <ForemanWeb.TicketDetail.priority_badge
                :if={@epic_priority}
                id="epic-priority"
                priority={@epic_priority.priority}
                changed={@epic_priority.changed_on_board}
              />
            </div>
            <ForemanWeb.TicketDetail.priority_controls
              :if={@epic_priority}
              id="epic-priority-controls"
              priority={@epic_priority}
              event="epic-priority"
            />
            <h1 id="epic-title" class="text-2xl font-semibold">{@epic.title}</h1>
            <p class="text-xs text-foreground-softer">
              {@epic.planned_count} planned · {@epic.fallout_count} fallout
            </p>
            <div class="flex gap-4">
              <ForemanWeb.TicketDetail.document_link
                :if={@epic.spec_link}
                id="epic-spec-link"
                label="Spec"
                repo={elem(@epic_key, 0)}
                path={@epic.spec_link}
              />
              <ForemanWeb.TicketDetail.document_link
                :if={@epic.design_link}
                id="epic-design-link"
                label="Design"
                repo={elem(@epic_key, 0)}
                path={@epic.design_link}
              />
            </div>
          </div>
          <ForemanWeb.PlanningSession.launch_button
            id="epic-launch"
            key={@epic_key}
            allowed={@launchable}
            session={@planning_session}
          />
          <div :if={@epic.total > 0} class="w-64 space-y-2">
            <p class="flex justify-between text-xs">
              <span>{@epic.closed} / {@epic.total} closed</span><span>{round(100 * @epic.closed / @epic.total)}%</span>
            </p>
            <div
              class="bb-progress"
              role="progressbar"
              aria-label="Epic progress"
              aria-valuenow={@epic.closed}
              aria-valuemax={@epic.total}
            >
              <span style={"width: #{100 * @epic.closed / @epic.total}%"}></span>
            </div>
          </div>
        </header>
        <section :if={@epic.design_link} id="epic-design" class="fm-markdown min-w-0">
          {Phoenix.HTML.raw(@design_html)}
        </section>
        <ForemanWeb.PlanningSession.status id="epic" session={@planning_session} />
        <section>
          <h2 class="bb-label mb-3">Epic stage history</h2>
          <div id="epic-history" phx-update="stream" class="flex flex-wrap gap-4">
            <ForemanWeb.TicketDetail.history_row
              :for={{id, event} <- @streams.epic_history}
              id={id}
              event={event}
              repo={elem(@epic_key, 0)}
            />
          </div>
        </section>
        <section class="space-y-3">
          <h2 class="bb-label">Tickets by stage</h2>
          <div class="overflow-x-auto pb-2">
            <div
              id="epic-columns"
              phx-update="stream"
              class="grid grid-rows-[auto_auto_auto] gap-x-3"
              style={"grid-template-columns: repeat(#{@epic.column_count}, minmax(190px, 1fr))"}
            >
              <section
                :for={{id, col} <- @streams.columns}
                id={id}
                class="row-span-3 grid grid-cols-[minmax(0,1fr)] grid-rows-subgrid"
                data-column={col.id}
              >
                <h3 class="mb-3 flex items-center gap-2 font-semibold">
                  {col.title}<Badge.badge>{length(col.planned ++ col.fallout)}</Badge.badge>
                </h3>
                <div
                  :for={{band, tickets} <- [{:planned, col.planned}, {:fallout, col.fallout}]}
                  :if={band == :planned or tickets != []}
                  data-band={band}
                  class={[
                    "mb-4 self-start space-y-2 rounded-lg p-2",
                    band == :planned && "min-h-20 bg-sunken",
                    band == :fallout && "border border-dashed border-warning"
                  ]}
                >
                  <h4 class="bb-label px-1 py-1">{band}</h4>
                  <.link
                    :for={ticket <- tickets}
                    patch={Foreman.TicketSheet.path(@page_uri, ticket.key)}
                    data-ticket={ticket.id}
                    data-stage={ticket.stage}
                    class="block space-y-2 rounded-lg border border-base bg-base p-3 shadow-sm transition-colors hover:border-foreground-softer"
                  >
                    <div class="flex flex-wrap justify-between gap-1 text-xs text-foreground-softer">
                      <span class="font-mono">{ticket.id}</span><span>{ticket.type}</span>
                    </div>
                    <p class="line-clamp-3 break-words text-[13px] font-medium leading-5">
                      {ticket.title}
                    </p>
                    <div class="flex flex-wrap gap-1">
                      <ForemanWeb.TicketDetail.priority_badge
                        priority={ticket.priority}
                        changed={ticket.priority_changed}
                      />
                      <Badge.badge color={stage_color(ticket.stage)}>{ticket.stage}</Badge.badge>
                      <Badge.badge>{ticket.status}</Badge.badge>
                    </div>
                  </.link>
                </div>
              </section>
            </div>
          </div>
        </section>
        <section class="min-w-0 max-w-full space-y-3">
          <h2 class="bb-label">Blocking graph</h2>
          <div
            id="blocking-graph"
            role="region"
            aria-label="Blocking graph"
            tabindex="0"
            class="bb-graph-scroll w-full min-w-0 max-w-full overflow-x-scroll rounded-lg border border-base bg-sunken"
          >
            <div
              class="relative"
              style={"width: #{@epic.graph.width}px; height: #{@epic.graph.height}px"}
            >
              <svg
                class="absolute inset-0 text-foreground-softer"
                width={@epic.graph.width}
                height={@epic.graph.height}
                aria-label="Blocker to blocked"
              >
                <defs>
                  <marker
                    id="block-arrow"
                    markerWidth="8"
                    markerHeight="8"
                    refX="7"
                    refY="3"
                    orient="auto"
                  >
                    <path d="M0,0 L0,6 L8,3 z" fill="currentColor" />
                  </marker>
                </defs>
                <g id="graph-edges" phx-update="stream">
                  <path
                    :for={{id, edge} <- @streams.graph_edges}
                    id={id}
                    data-from={elem(edge.from, 1)}
                    data-to={elem(edge.to, 1)}
                    d={edge.path}
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.5"
                    marker-end="url(#block-arrow)"
                  />
                </g>
              </svg>
              <div id="graph-nodes" phx-update="stream">
                <.link
                  :for={{id, node} <- @streams.graph_nodes}
                  id={id}
                  patch={Foreman.TicketSheet.path(@page_uri, node.key)}
                  style={"left: #{node.x}px; top: #{node.y}px"}
                  class={[
                    "absolute flex h-20 w-[190px] flex-col justify-center gap-1 rounded-lg border bg-base px-3 shadow-sm transition-colors hover:border-foreground-softer",
                    node.fallout && "border-dashed border-warning",
                    node.external && "border-dashed border-base",
                    !node.fallout && !node.external && "border-base"
                  ]}
                >
                  <span class="flex justify-between gap-1 font-mono text-[11px]">
                    <span>{elem(node.key, 1)}</span><span class="text-foreground-softer">{node.stage || "external"}</span>
                  </span>
                  <span class="line-clamp-2 text-xs">{node.title}</span>
                </.link>
              </div>
            </div>
          </div>
        </section>
      <% else %>
        <h1 id="epic-not-found" class="text-xl font-semibold">Epic not found</h1>
      <% end %>
      <ForemanWeb.TicketDetail.sheet
        ticket={@ticket}
        state={@sheet_state}
        tab={@ticket_tab}
        uri={@page_uri}
        return_to={@sheet_return}
        streams={@streams}
      />
    </Layouts.app>
    """
  end

  defp home_path(uri) do
    query = URI.parse(Foreman.TicketSheet.path(uri)).query
    "/" <> if(query, do: "?" <> query, else: "")
  end

  defp stage_color(stage) when stage in [:building, :dispatched], do: "info"
  defp stage_color(stage) when stage in [:reported, :in_review], do: "warning"
  defp stage_color(stage) when stage in [:committed, :pr_open, :merged, :done], do: "success"
  defp stage_color(_), do: "neutral"
end
