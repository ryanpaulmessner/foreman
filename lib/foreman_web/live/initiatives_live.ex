defmodule ForemanWeb.InitiativesLive do
  use ForemanWeb, :live_view
  alias Fluxon.Components.{Badge, Button}
  alias Foreman.Initiatives.{Disclosure, Filters, FilterRestore}

  @kind_streams ~w(break_fix mapping access feature internal unsorted)a

  @impl true
  def mount(_, _, socket) do
    if connected?(socket) do
      Foreman.Events.subscribe()
      Process.send_after(self(), :reconcile, 3_000)
    end

    connect = get_connect_params(socket) || %{}
    remembered = connect["initiative_filters"]

    {disclosure, []} =
      if connect["initiative_filters_open"] in [true, "true"],
        do: Disclosure.step(Disclosure.__fsm__(:initial), :toggle, %{}),
        else: {Disclosure.__fsm__(:initial), []}

    options = Map.take(Foreman.Initiatives.snapshot(), [:repos, :types, :labels, :views])

    {:ok,
     socket
     |> assign(
       filters: %{},
       filter_disclosure: disclosure,
       remembered_filters: remembered,
       filter_restore: FilterRestore.__fsm__(:initial),
       expanded: %{}
     )
     |> assign(options)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    remembered = socket.assigns.remembered_filters

    {state, effects} =
      FilterRestore.step(socket.assigns.filter_restore, {:params, params}, remembered)

    restore? = Keyword.has_key?(effects, :restore)
    filters = Filters.normalize(if(restore?, do: remembered, else: params), socket.assigns)

    socket =
      socket
      |> assign(filters: filters, filter_restore: state)
      |> ForemanWeb.TicketDetail.load(params, uri)
      |> refresh()

    {:noreply,
     if(restore?, do: push_patch(socket, to: Filters.path(filters), replace: true), else: socket)}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    filters = Filters.normalize(Map.merge(socket.assigns.filters, filters), socket.assigns)
    {:noreply, push_patch(socket, to: Filters.path(filters))}
  end

  def handle_event("coordinator", %{"action" => action}, socket) do
    result =
      case action do
        "focus" ->
          case Foreman.Sessions.coordinator() do
            nil -> {:error, :not_relaunchable}
            session -> Foreman.SessionTmux.focus(session)
          end

        "resume" ->
          Foreman.Sessions.launch_coordinator(:resume)

        "fresh" ->
          Foreman.Sessions.launch_coordinator(:fresh)
      end

    socket =
      case result do
        {:error, reason} -> put_flash(socket, :error, Foreman.Sessions.error_message(reason))
        _ -> socket
      end

    {:noreply, refresh(socket)}
  end

  def handle_event("launch-session", params, socket),
    do: {:noreply, socket |> ForemanWeb.PlanningSession.launch(params) |> refresh()}

  def handle_event("preview", params, socket),
    do: {:noreply, ForemanWeb.TicketDetail.preview(socket, params)}

  def handle_event("close-ticket", params, socket),
    do: {:noreply, ForemanWeb.TicketDetail.close(socket, params)}

  def handle_event("ticket-priority", params, socket),
    do: {:noreply, socket |> ForemanWeb.TicketDetail.priority(params) |> refresh()}

  def handle_event("ticket-jump", params, socket),
    do: {:noreply, socket |> ForemanWeb.TicketDetail.jump(params) |> refresh()}

  def handle_event("toggle-filters", _, socket) do
    {state, []} = Disclosure.step(socket.assigns.filter_disclosure, :toggle, %{})
    {:noreply, assign(socket, :filter_disclosure, state)}
  end

  def handle_event("view", %{"key" => key}, socket) do
    filters = socket.assigns.filters |> Map.merge(%{"view" => key, "status" => "", "stale" => ""})
    filters = Filters.normalize(filters, socket.assigns)
    {:noreply, push_patch(socket, to: Filters.path(filters))}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    {state, []} = Disclosure.step(Map.get(socket.assigns.expanded, id, :collapsed), :toggle, %{})

    {:noreply,
     socket |> assign(:expanded, Map.put(socket.assigns.expanded, id, state)) |> refresh()}
  end

  @impl true
  def handle_info(:reconcile, socket) do
    Process.send_after(self(), :reconcile, 3_000)
    {:noreply, refresh(socket)}
  end

  def handle_info({:notification, :foreman_events, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    socket = ForemanWeb.TicketDetail.refresh(socket)
    data = Foreman.Initiatives.snapshot(socket.assigns.filters)
    filters = Filters.normalize(socket.assigns.filters, data)
    socket = assign(socket, :filters, filters)

    {finished, active} = Enum.split_with(data.epics, &finished?/1)
    {finished_drafts, drafts} = Enum.split_with(data.drafts, &finished?/1)

    finished =
      (finished ++
         Enum.map(
           finished_drafts,
           &Map.merge(&1, %{
             planned: [],
             fallout: [],
             children: [],
             total: 0,
             closed: 0,
             histogram: %{}
           })
         ))
      |> Enum.sort_by(&Foreman.Beads.Id.sort_key(&1.key))

    done_rows =
      if expanded?(socket.assigns.expanded, "done"),
        do:
          Enum.flat_map(
            finished,
            &epic_rows(&1, socket.assigns.expanded, data.filters, 0, "")
          ),
        else: []

    socket =
      Enum.reduce(@kind_streams, socket, fn kind, socket ->
        section = Enum.find(data.sections, &(&1.kind == to_string(kind)))

        rows =
          if section,
            do: kind_rows(section, socket.assigns.expanded, data.filters, data.swimlanes),
            else: []

        stream(socket, kind, rows, reset: true)
      end)

    socket
    |> assign(
      kind_sections: Enum.map(data.sections, &Map.take(&1, [:kind, :label, :count])),
      kind_streams: @kind_streams,
      coordinator: Foreman.Sessions.coordinator(),
      repos: data.repos,
      columns: data.columns,
      views: data.views,
      types: data.types,
      labels: data.labels,
      draft_count: length(drafts),
      epic_count: length(active),
      done_count: length(finished),
      parked_count: length(data.parked),
      advanced_count: Filters.advanced_count(filters, data.views),
      form: to_form(socket.assigns.filters, as: :filters)
    )
    |> stream(:drafts, Enum.map(drafts, &Map.put(&1, :id, dom_key(&1.key))), reset: true)
    |> stream(:done, done_rows, reset: true)
    |> stream(:parked, project_rows(data.parked, socket.assigns.expanded, "parked", "parked-"),
      reset: true
    )
  end

  defp kind_rows(section, expanded, filters, swimlanes) do
    epics =
      Enum.flat_map(
        section.epics,
        &epic_rows(&1, expanded, filters, 0, "")
      )

    loose =
      Enum.flat_map([{:in_flight, "In flight"}, {:never_started, "Never started"}], fn {bucket,
                                                                                        title} ->
        id = "kind-#{section.kind}-#{bucket}"
        tickets = Map.fetch!(section, bucket)

        rows =
          if swimlanes == "project" do
            project_rows(tickets, Map.put(expanded, id, :expanded), id, id <> "-")
          else
            Enum.map(tickets, &ticket_row(&1, 0, id))
          end

        section_rows(rows, title, id, 0)
      end)

    epics ++ loose
  end

  defp project_rows(tickets, expanded, section, prefix) do
    if expanded?(expanded, section) do
      tickets
      |> Enum.group_by(& &1.repo)
      |> Enum.sort()
      |> Enum.flat_map(fn {repo, tickets} ->
        id = prefix <> "project-" <> repo

        [%{id: id, kind: :project, repo: repo, count: length(tickets), depth: 0}] ++
          if(expanded?(expanded, id),
            do: Enum.map(tickets, &ticket_row(&1, 1, id)),
            else: []
          )
      end)
    else
      []
    end
  end

  defp epic_rows(epic, expanded, filters, depth, prefix) do
    id = prefix <> dom_key(epic.key)

    row =
      Map.merge(epic, %{
        id: id,
        bead_id: epic.id,
        kind: :epic,
        depth: depth,
        stale: Enum.any?(epic.planned ++ epic.fallout, & &1.stale)
      })

    if expanded?(expanded, id) do
      nested_keys = Enum.reduce(epic.children, MapSet.new(), &MapSet.union(&1.members, &2))

      own = fn tickets ->
        Enum.reject(tickets, &MapSet.member?(nested_keys, &1.key))
        |> Enum.filter(&Foreman.Initiatives.matches?(&1, filters))
      end

      children =
        Enum.flat_map(epic.children, &epic_rows(&1, expanded, filters, depth + 1, id <> "-"))

      planned = Enum.map(own.(epic.planned), &ticket_row(&1, depth + 1, id <> "-planned"))
      fallout = Enum.map(own.(epic.fallout), &ticket_row(&1, depth + 1, id <> "-fallout"))

      [row] ++
        children ++
        section_rows(planned, "Planned", id <> "-planned", depth + 1) ++
        section_rows(fallout, "Fallout", id <> "-fallout", depth + 1)
    else
      [row]
    end
  end

  defp section_rows([], _, _, _), do: []

  defp section_rows(rows, title, id, depth),
    do: [%{kind: :section, title: title, id: id, depth: depth} | rows]

  defp ticket_row(ticket, depth, prefix),
    do:
      Map.merge(ticket, %{
        id: prefix <> "-" <> dom_key(ticket.key),
        bead_id: ticket.id,
        kind: :ticket,
        depth: depth
      })

  defp epic_path({repo, id}, uri) do
    query = URI.parse(Foreman.TicketSheet.path(uri)).query
    ~p"/epics/#{repo}/#{id}" <> if(query, do: "?" <> query, else: "")
  end

  defp finished?(epic), do: epic.stage in [:done, :shipped]
  defp dom_key({repo, id}), do: Base.url_encode64(repo <> "/" <> id, padding: false)
  defp expanded?(expanded, id), do: Map.get(expanded, id, :collapsed) == :expanded
  defp percentage(%{total: 0}), do: 0
  defp percentage(row), do: round(100 * row.closed / row.total)
  defp stage_color(stage) when stage in [:building, :dispatched], do: "info"

  defp stage_color(stage) when stage in [:shipping, :shipped, :committed, :pr_open, :merged],
    do: "success"

  defp stage_color(stage) when stage in [:speccing, :spec_approved, :reported, :in_review],
    do: "warning"

  defp stage_color(_), do: "neutral"

  defp histogram(row, columns) do
    Enum.map(columns, fn col ->
      count =
        Enum.reduce(col["stages"], 0, fn stage, acc ->
          acc +
            Enum.find_value(row.histogram, 0, fn {key, n} -> if to_string(key) == stage, do: n end)
        end)

      %{title: col["title"], count: count}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      drawer_state={@drawer_state}
      drawer_error={@drawer_error}
      streams={@streams}
      flash={@flash}
      pending_count={@pending_count}
      active={:initiatives}
      repos={@repos}
      filters={@filters}
    >
      <div
        id="initiative-filter-memory"
        phx-hook="InitiativeFilters"
        data-filters={Jason.encode!(@filters)}
        data-filters-open={to_string(@filter_disclosure == :expanded)}
        hidden
      >
      </div>
      <header class="flex items-center justify-between gap-4">
        <h1 class="text-[22px] font-semibold text-foreground">Initiatives</h1>
        <span class="text-xs text-foreground-softer">
          {@draft_count} drafts · {@epic_count} active · {@done_count} done
        </span>
      </header>
      <section
        id="coordinator"
        class="flex flex-wrap items-center gap-3 rounded-lg border border-foreground/10 px-4 py-3 text-sm"
      >
        <span class="font-medium">Coordinator</span>
        <span id="coordinator-state" class="text-foreground-softer">
          {if @coordinator, do: @coordinator.state, else: "Not started"}
        </span>
        <div class="ml-auto flex flex-wrap gap-2">
          <Button.button
            id="coordinator-focus"
            size="sm"
            variant="ghost"
            phx-click="coordinator"
            phx-value-action="focus"
            disabled={is_nil(@coordinator) or is_nil(@coordinator.window)}
          >
            Focus
          </Button.button>
          <Button.button
            id="coordinator-relaunch"
            size="sm"
            variant="outline"
            phx-click="coordinator"
            phx-value-action="resume"
            disabled={@coordinator && @coordinator.state in [:starting, :running, :waiting]}
          >
            Relaunch
          </Button.button>
          <Button.button
            id="coordinator-fresh"
            size="sm"
            variant="ghost"
            phx-click="coordinator"
            phx-value-action="fresh"
            data-confirm="Start a new coordinator conversation?"
            disabled={@coordinator && @coordinator.state in [:starting, :running, :waiting]}
          >
            Start fresh
          </Button.button>
        </div>
      </section>
      <.form
        for={@form}
        id="initiative-filters"
        phx-change="filter"
        phx-submit="filter"
        class="bb-filters space-y-3"
      >
        <div class="flex flex-wrap items-end gap-3">
          <Button.button_group id="initiative-views" aria-label="Views">
            <Button.button
              :for={view <- @views}
              id={"view-" <> view["key"]}
              type="button"
              phx-click="view"
              phx-value-key={view["key"]}
              aria-pressed={to_string(@filters["view"] == view["key"])}
              variant={if @filters["view"] == view["key"], do: "solid", else: "outline"}
            >
              {view["title"]}
            </Button.button>
          </Button.button_group>
          <.input
            field={@form[:q]}
            type="search"
            class="bb-filter-control"
            aria-label="Search"
            placeholder="Search"
            phx-debounce="200"
          />
        </div>
        <button
          type="button"
          id="toggle-filters"
          phx-click="toggle-filters"
          aria-expanded={to_string(@filter_disclosure == :expanded)}
          aria-controls="advanced-filters"
          class="flex items-center gap-2 text-sm text-foreground-softer hover:text-foreground"
        >
          <.icon
            name={
              if @filter_disclosure == :expanded, do: "hero-chevron-down", else: "hero-chevron-right"
            }
            class="size-3"
          /> Filters
          <span
            :if={@filter_disclosure == :collapsed and @advanced_count > 0}
            id="advanced-filter-count"
            class="rounded bg-sunken px-1.5 text-xs"
          >
            {@advanced_count}
          </span>
        </button>
        <div
          id="advanced-filters"
          hidden={@filter_disclosure == :collapsed}
          class={
            if @filter_disclosure == :collapsed, do: "hidden", else: "flex flex-wrap items-end gap-3"
          }
        >
          <.input
            field={@form[:status]}
            type="select"
            class="bb-filter-control"
            label="Beads status"
            options={[
              {"View default", ""},
              {"All", "all"},
              {"Open", "open"},
              {"Closed", "closed"},
              {"In progress", "in_progress"},
              {"Blocked", "blocked"},
              {"Deferred", "deferred"},
              {"Parked", "parked"}
            ]}
          />
          <.input
            field={@form[:type]}
            type="select"
            class="bb-filter-control"
            label="Type"
            options={[{"Any", ""} | Enum.map(@types, &{&1, &1})]}
          />
          <.input
            field={@form[:kind]}
            type="select"
            class="bb-filter-control"
            label="Kind"
            options={[
              {"All", ""}
              | Enum.map(Foreman.Initiatives.Kinds.options(), fn {kind, label} -> {label, kind} end)
            ]}
          />
          <.input
            field={@form[:label]}
            type="select"
            class="bb-filter-control"
            label="Label"
            options={[{"Any", ""} | Enum.map(@labels, &{&1, &1})]}
          />
          <.input
            field={@form[:stale]}
            type="select"
            class="bb-filter-control"
            label="Stale"
            options={[{"View default", ""}, {"Only stale", "true"}, {"Any", "false"}]}
          />
        </div>
      </.form>
      <div
        :for={repo <- @repos}
        :if={
          repo["health"].state == "unreachable" and
            @filters["project"] in [nil, "", "all", repo["key"]]
        }
        class="rounded-lg border border-warning bg-warning-soft px-4 py-3 text-sm"
        role="status"
      >
        {repo["key"]} · unreachable
      </div>
      <section :if={@draft_count > 0} id="drafts-panel" class="bb-initiative-panel">
        <h2 class="bb-section-title">
          Drafts <span class="text-foreground-softer">{@draft_count}</span>
        </h2>
        <div id="drafts" phx-update="stream">
          <div
            :for={{id, draft} <- @streams.drafts}
            id={id}
            data-bead={elem(draft.key, 1)}
            class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-3 border-t border-base p-4 md:grid-cols-[100px_minmax(0,1fr)_100px_minmax(0,1fr)_auto]"
          >
            <span class="hidden text-xs md:block">{draft.repo}</span>
            <div class="min-w-0">
              <.link
                navigate={epic_path(draft.key, @page_uri)}
                class="block truncate font-medium hover:underline"
              >
                {draft.title}
              </.link>
              <span class="font-mono text-xs text-foreground-softer">{elem(draft.key, 1)}</span>
            </div>
            <Badge.badge color={stage_color(draft.stage)}>{draft.stage}</Badge.badge>
            <span class="min-w-0 truncate font-mono text-xs">
              <ForemanWeb.TicketDetail.document_link
                :if={draft.spec_link}
                repo={elem(draft.key, 0)}
                path={draft.spec_link}
              /><span :if={!draft.spec_link}>—</span>
            </span>
            <ForemanWeb.PlanningSession.launch_button
              id={"launch-" <> id}
              key={draft.key}
              allowed={Foreman.Sessions.launchable?(draft)}
              session={draft.planning_session}
            />
          </div>
        </div>
      </section>
      <.parentless_section
        id="parked"
        title="Parked"
        count={@parked_count}
        rows={@streams.parked}
        expanded={@expanded}
        uri={@page_uri}
      />
      <section
        :for={section <- @kind_sections}
        id={"kind-#{section.kind}-panel"}
        class="bb-initiative-panel overflow-x-auto"
      >
        <h2 class="bb-section-title">
          {section.label}
          <span id={"kind-#{section.kind}-count"} class="text-foreground-softer">
            {section.count}
          </span>
        </h2>
        <.epic_list
          id={"kind-#{section.kind}"}
          rows={Map.fetch!(@streams, Enum.find(@kind_streams, &(to_string(&1) == section.kind)))}
          expanded={@expanded}
          columns={@columns}
          uri={@page_uri}
        />
      </section>
      <section id="done-panel" class="bb-initiative-panel overflow-x-auto">
        <button
          id="toggle-done"
          class="bb-section-title w-full text-left"
          phx-click="toggle"
          phx-value-id="done"
          aria-expanded={to_string(expanded?(@expanded, "done"))}
        >
          <.icon
            name={
              if expanded?(@expanded, "done"), do: "hero-chevron-down", else: "hero-chevron-right"
            }
            class="size-4"
          /> Done <span id="done-count" class="text-foreground-softer">{@done_count}</span>
        </button>
        <.epic_list
          :if={expanded?(@expanded, "done")}
          id="done"
          rows={@streams.done}
          uri={@page_uri}
          expanded={@expanded}
          columns={@columns}
        />
      </section>

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

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :count, :integer, required: true
  attr :rows, :any, required: true
  attr :expanded, :map, required: true
  attr :uri, :string, required: true

  defp parentless_section(assigns) do
    ~H"""
    <section id={@id <> "-panel"} class="bb-initiative-panel">
      <button
        id={"toggle-" <> @id}
        class="bb-section-title w-full text-left"
        phx-click="toggle"
        phx-value-id={@id}
        aria-expanded={to_string(expanded?(@expanded, @id))}
      >
        <.icon
          name={
            if expanded?(@expanded, @id),
              do: "hero-chevron-down",
              else: "hero-chevron-right"
          }
          class="size-4"
        />{@title} <span id={@id <> "-count"} class="text-foreground-softer">{@count}</span>
      </button>
      <div id={@id} phx-update="stream">
        <div :for={{id, row} <- @rows} id={id} data-bead={Map.get(row, :bead_id)}>
          <%= if row.kind == :project do %>
            <button
              id={"toggle-" <> row.id}
              class="flex w-full items-center gap-3 border-t border-base px-5 py-3 text-left"
              phx-click="toggle"
              phx-value-id={row.id}
              aria-expanded={to_string(expanded?(@expanded, row.id))}
            >
              <.icon
                name={
                  if expanded?(@expanded, row.id),
                    do: "hero-chevron-down",
                    else: "hero-chevron-right"
                }
                class="size-3"
              />{row.repo}<span class="text-xs text-foreground-softer">{row.count}</span>
            </button>
          <% else %>
            <.ticket row={row} uri={@uri} />
          <% end %>
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :rows, :any, required: true
  attr :expanded, :map, required: true
  attr :columns, :list, required: true
  attr :uri, :string, required: true

  defp epic_list(assigns) do
    ~H"""
    <div class="bb-initiative-grid bb-initiative-head">
      <span>Project</span><span>Epic</span><span>Stage</span><span>Progress</span><span>Stages</span><span>Fallout</span><span>CRs</span>
    </div>
    <div id={@id} phx-update="stream">
      <div id={@id <> "-empty"} class="hidden p-5 text-foreground-softer only:block">
        No matching epics
      </div>
      <div
        :for={{id, row} <- @rows}
        id={id}
        data-bead={Map.get(row, :bead_id)}
        data-kind={row.kind}
        data-stage={Map.get(row, :stage)}
      >
        <%= case row.kind do %>
          <% :epic -> %>
            <div class="bb-initiative-grid bb-initiative-row w-full text-left hover:bg-sunken">
              <span class="truncate text-xs">{row.repo}</span>
              <div
                class="flex min-w-0 items-center gap-2"
                style={"padding-left: #{row.depth * 16}px"}
              >
                <button
                  type="button"
                  id={"toggle-" <> row.id}
                  phx-click="toggle"
                  phx-value-id={row.id}
                  aria-label={"Expand " <> row.bead_id}
                  aria-expanded={to_string(expanded?(@expanded, row.id))}
                >
                  <.icon
                    name={
                      if expanded?(@expanded, row.id),
                        do: "hero-chevron-down",
                        else: "hero-chevron-right"
                    }
                    class="size-3 shrink-0"
                  />
                </button>
                <div class="min-w-0">
                  <.link
                    navigate={epic_path(row.key, @uri)}
                    class="block truncate font-medium hover:underline"
                    title={row.title}
                  >
                    {row.title}
                  </.link>
                  <span class="font-mono text-xs text-foreground-softer">{row.bead_id}</span>
                  <ForemanWeb.TicketDetail.priority_badge
                    priority={Map.get(row, :priority)}
                    changed={Map.get(row, :priority_changed, false)}
                  />
                  <Badge.badge :if={row.stale} color="warning" class="ml-2">stale</Badge.badge>
                </div>
              </div>
              <div>
                <Badge.badge color={stage_color(row.stage)}>{row.stage}</Badge.badge>
                <ForemanWeb.PlanningSession.launch_button
                  id={"launch-" <> id}
                  key={row.key}
                  allowed={Foreman.Sessions.launchable?(row)}
                  session={row.planning_session}
                />
              </div>
              <div class="bb-epic-progress space-y-1.5">
                <span
                  :if={row.total == 0}
                  class="text-xs text-foreground-softer"
                  aria-label="No child tickets"
                >
                  —
                </span>
                <div :if={row.total > 0} class="flex justify-between text-xs">
                  <span>{row.closed} / {row.total}</span><span class="text-foreground-softer">{percentage(row)}%</span>
                </div>
                <div
                  :if={row.total > 0}
                  class="bb-progress"
                  role="progressbar"
                  aria-valuenow={row.closed}
                  aria-valuemax={row.total}
                  aria-label={"#{row.bead_id} progress"}
                >
                  <span style={"width: #{percentage(row)}%"}></span>
                </div>
              </div>
              <div
                class="bb-histogram"
                role="img"
                aria-label={
                  Enum.map_join(histogram(row, @columns), ", ", &"#{&1.title}: #{&1.count}")
                }
              >
                <span
                  :for={{bar, index} <- Enum.with_index(histogram(row, @columns))}
                  class={"bb-hist-#{rem(index, 5)}"}
                  style={"height: #{max(2, round(26 * bar.count / max(row.total, 1)))}px"}
                  title={"#{bar.title}: #{bar.count}"}
                >
                </span>
              </div>
              <span class="text-xs">{Map.get(row, :fallout_count, length(row.fallout))}</span>
              <span
                class="text-xs text-foreground-softer"
                data-cr-count={row.cr_count}
                aria-label={"#{row.cr_count} open change requests"}
              >
                {row.cr_count}
              </span>
            </div>
          <% :project -> %>
            <button
              id={"toggle-" <> row.id}
              class="flex w-full items-center gap-3 border-t border-base px-5 py-3 text-left"
              phx-click="toggle"
              phx-value-id={row.id}
              aria-expanded={to_string(expanded?(@expanded, row.id))}
            >
              <.icon
                name={
                  if expanded?(@expanded, row.id), do: "hero-chevron-down", else: "hero-chevron-right"
                }
                class="size-3"
              />
              {row.repo}<span class="text-xs text-foreground-softer">{row.count}</span>
            </button>
          <% :section -> %>
            <h3 class="bb-section-label" style={"padding-left: #{24 + row.depth * 16}px"}>
              {row.title}
            </h3>
          <% :ticket -> %>
            <.ticket row={row} uri={@uri} />
        <% end %>
      </div>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :uri, :string, required: true

  defp ticket(assigns) do
    ~H"""
    <.link
      patch={Foreman.TicketSheet.path(@uri, @row.key)}
      class="bb-ticket items-center gap-3 border-t border-base px-5 py-3 hover:bg-sunken"
      style={"padding-left: #{24 + @row.depth * 16}px"}
    >
      <span class="bb-ticket-id shrink-0 truncate font-mono text-xs text-foreground-softer md:w-28">
        {@row.bead_id}
      </span>
      <span class="bb-ticket-title min-w-0 flex-1 text-sm">
        {@row.title}
        <span
          :if={Map.has_key?(@row, :parked_epics)}
          class="block text-xs text-foreground-softer break-words"
        >
          <span :for={epic <- @row.parked_epics} class="block">{epic.id} · {epic.title}</span>
          {@row.parked_reason}
          <time
            :if={@row.parked_at}
            datetime={DateTime.to_iso8601(@row.parked_at)}
            title={"Parked " <> Calendar.strftime(@row.parked_at, "%B %-d, %Y")}
          >
            · {ForemanWeb.TicketAge.format(DateTime.to_date(@row.parked_at))}
          </time>
        </span>
      </span>
      <Badge.badge :if={@row.status == "parked"}>Parked</Badge.badge>
      <ForemanWeb.TicketDetail.priority_badge
        priority={Map.get(@row, :priority)}
        changed={Map.get(@row, :priority_changed, false)}
      />
      <Badge.badge class="bb-ticket-stage" color={stage_color(@row.stage)}>{@row.stage}</Badge.badge>
      <span class="text-xs text-foreground-softer">
        {@row.type} · {@row.status}<span :if={@row.created_at}> · <time
            id={"age-" <> @row.id}
            datetime={DateTime.to_iso8601(@row.created_at)}
            title={"Created " <> Calendar.strftime(@row.created_at, "%B %-d, %Y")}
          >{ForemanWeb.TicketAge.format(DateTime.to_date(@row.created_at))}</time></span>
      </span>
      <Badge.badge :if={@row.stale} color="warning">stale</Badge.badge>
    </.link>
    """
  end
end
