defmodule ForemanWeb.SessionsLive do
  use ForemanWeb, :live_view
  alias Foreman.{AgentSession, AgentSessions, Repo}
  alias ForemanWeb.{SessionState, SessionTree, SessionGrid}
  alias Foreman.{GridReader, GridOutput, PaneCapture}
  import Ecto.Query

  def mount(_, _, socket) do
    if connected?(socket) do
      Foreman.Events.subscribe()
      send(self(), :check_connection)
    end

    {:ok,
     socket
     |> assign(
       connection: :connecting,
       sessions_view: :tree,
       grid_reader: :off,
       check_timer: nil,
       check_token: nil,
       page_visible: true,
       visible_ids: MapSet.new(),
       grid_read_at: %{},
       grid_hashes: %{},
       grid_rows: %{},
       updated_at: DateTime.utc_now(),
       disclosures: %{},
       ended: :collapsed,
       waiting: :collapsed,
       note: :collapsed,
       result: nil,
       note_form: note_form(),
       repos: Foreman.RuntimeState.repos()
     )
     |> stream_configure(:grid_items, dom_id: &"grid-item-#{&1.id}")
     |> stream_configure(:rows, dom_id: &"tree-row-#{&1.id}")
     |> stream_configure(:waiting_rows, dom_id: &"waiting-#{&1.id}")
     |> refresh()}
  end

  def handle_info({:notification, :foreman_events, _}, socket), do: {:noreply, refresh(socket)}

  def handle_info({:check_connection, token}, %{assigns: %{check_token: token}} = socket),
    do: handle_info(:check_connection, socket)

  def handle_info({:check_connection, _}, socket), do: {:noreply, socket}

  def handle_info(:check_connection, socket) do
    socket = cancel_check(socket)

    socket =
      cond do
        socket.assigns.sessions_view == :grid -> read_grid(socket)
        not socket.assigns.page_visible -> schedule_check(socket)
        true -> socket |> check_connection() |> schedule_check()
      end

    {:noreply, socket}
  end

  def handle_event("retry", _, socket) do
    if socket.assigns.sessions_view == :tree do
      {:noreply, check_connection(socket)}
    else
      {state, effects} = GridReader.step(socket.assigns.grid_reader, :retry, %{})
      {:noreply, socket |> assign(:grid_reader, state) |> reader_effects(effects)}
    end
  end

  def handle_event("sessions-view", %{"view" => view}, socket),
    do: change_view(socket, view, true)

  def handle_event("restore-sessions-view", %{"view" => view}, socket),
    do: change_view(socket, view, false)

  def handle_event("grid_visibility", %{"ids" => ids, "visible" => visible}, socket)
      when is_list(ids) and is_boolean(visible) do
    ids = ids |> Enum.filter(&Map.has_key?(socket.assigns.grid_rows, &1)) |> MapSet.new()
    {:noreply, socket |> assign(visible_ids: ids, page_visible: visible) |> reader_view()}
  end

  def handle_event("toggle-ended", _, socket),
    do: {:noreply, socket |> toggle(:ended) |> refresh()}

  def handle_event("toggle-waiting", _, socket),
    do: {:noreply, socket |> toggle(:waiting) |> refresh()}

  def handle_event("toggle-note", _, socket), do: {:noreply, toggle(socket, :note)}

  def handle_event("collapse", %{"id" => id}, socket) do
    if id in socket.assigns.coordinator_ids do
      current = Map.get(socket.assigns.disclosures, id, :expanded)
      {next, []} = Foreman.Initiatives.Disclosure.step(current, :toggle, %{})

      {:noreply,
       socket
       |> assign(:disclosures, Map.put(socket.assigns.disclosures, id, next))
       |> refresh()
       |> push_event("save-collapse", %{id: id, collapsed: next == :collapsed})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("restore-collapse", %{"ids" => ids}, socket) when is_list(ids) do
    disclosures =
      Map.new(Enum.filter(ids, &(&1 in socket.assigns.coordinator_ids)), &{&1, :collapsed})

    {:noreply, socket |> assign(:disclosures, disclosures) |> refresh()}
  end

  def handle_event("focus", %{"id" => id}, socket) do
    result =
      with false <- socket.assigns.connection == :tmux_error,
           %AgentSession{} = row <- AgentSessions.get(id),
           :ok <- Foreman.RequestSource.focus(Foreman.RequestSource.source(row), tmux_opts()) do
        {:success, "Brought #{row.name} to the front."}
      else
        {:error, :no_client} ->
          {:info, "No terminal is attached. Copy the attach command from Details."}

        _ ->
          {:error, "Could not focus the terminal. Open the session for details."}
      end

    {:noreply, assign(socket, :result, result)}
  end

  def handle_event("start-main", _, socket) do
    case Foreman.Sessions.launch_coordinator(:resume, tmux_opts()) do
      {:ok, _} ->
        {:noreply, refresh(socket)}

      {:error, reason} ->
        {:noreply, assign(socket, :result, {:error, Foreman.Sessions.error_message(reason)})}
    end
  end

  def handle_event("send-note", %{"note" => %{"text" => text}}, socket) do
    case Foreman.CoordinatorNote.send("claude", "board", text, tmux_opts()) do
      {:ok, %{delivered: delivered, skipped: skipped}} ->
        {:noreply,
         assign(socket, note_form: note_form(), result: {:note, length(delivered), skipped})}

      {:error, _} ->
        {:noreply,
         assign(socket, note_form: note_form(text), result: {:error, "Enter a note to send."})}
    end
  end

  defp change_view(socket, view, save?) when view in ["tree", "grid"] do
    event = if view == "grid", do: :grid, else: :tree
    {next, []} = Foreman.SessionsView.step(socket.assigns.sessions_view, event, %{})

    socket =
      socket
      |> assign(sessions_view: next, visible_ids: MapSet.new(), grid_hashes: %{})
      |> reader_view()
      |> refresh()

    {:noreply,
     if(save?, do: push_event(socket, "save-sessions-view", %{view: view}), else: socket)}
  end

  defp change_view(socket, _, _), do: {:noreply, socket}

  defp reader_view(socket) do
    {next, effects} =
      GridReader.step(
        socket.assigns.grid_reader,
        {:view,
         %{shown: socket.assigns.sessions_view == :grid, visible: socket.assigns.page_visible}},
        %{}
      )

    socket |> assign(:grid_reader, next) |> reader_effects(effects)
  end

  defp reader_effects(socket, effects) do
    Enum.reduce(effects, socket, fn
      {:cancel, :capture}, acc ->
        cancel_async(acc, :grid_capture)

      {:timer, :check}, acc ->
        schedule_check(acc)

      {:retry, :visible}, acc ->
        assign(
          acc,
          :grid_read_at,
          Map.drop(acc.assigns.grid_read_at, MapSet.to_list(acc.assigns.visible_ids))
        )
    end)
  end

  defp cancel_check(socket) do
    if socket.assigns.check_timer, do: Process.cancel_timer(socket.assigns.check_timer)
    assign(socket, check_timer: nil, check_token: nil)
  end

  defp schedule_check(socket) do
    socket = cancel_check(socket)
    token = make_ref()
    timer = Process.send_after(self(), {:check_connection, token}, 3_000)
    assign(socket, check_timer: timer, check_token: token)
  end

  defp read_grid(socket) do
    clock =
      Application.get_env(:foreman, :grid_clock, fn -> System.monotonic_time(:millisecond) end)

    now = clock.()

    rows =
      GridReader.due(
        Map.values(socket.assigns.grid_rows),
        socket.assigns.visible_ids,
        socket.assigns.grid_read_at,
        now
      )

    {state, effects} =
      GridReader.step(socket.assigns.grid_reader, {:tick, %{due: rows != []}}, %{})

    socket = assign(socket, :grid_reader, state)

    if effects == [capture: :visible] do
      targets = Enum.map(rows, &Map.put(PaneCapture.target(&1), :id, &1.id))
      read_at = Enum.reduce(rows, socket.assigns.grid_read_at, &Map.put(&2, &1.id, now))

      socket
      |> assign(:grid_read_at, read_at)
      |> start_async(:grid_capture, fn -> {rows, PaneCapture.read_batch(targets)} end)
    else
      reader_effects(socket, effects)
    end
  end

  def handle_async(:grid_capture, result, socket) do
    if socket.assigns.grid_reader != :capturing do
      {:noreply, socket}
    else
      {rows, results} =
        case result do
          {:ok, batch} -> batch
          {:exit, _} -> {[], %{failed: {:error, :tmux_unavailable}}}
        end

      rows =
        Enum.filter(rows, fn row ->
          current = socket.assigns.grid_rows[row.id]

          current && is_nil(current.ended_at) &&
            PaneCapture.target(current) == PaneCapture.target(row) &&
            MapSet.member?(socket.assigns.visible_ids, row.id)
        end)

      socket =
        Enum.reduce(rows, socket, fn row, acc ->
          case results[row.id] do
            {:ok, text} ->
              excerpt = GridOutput.excerpt(text, row.harness)
              hash = PaneCapture.hash(excerpt)

              if acc.assigns.grid_hashes[row.id] == hash do
                acc
              else
                {:safe, html} = ForemanWeb.AnsiHtml.to_html(excerpt)

                acc
                |> assign(:grid_hashes, Map.put(acc.assigns.grid_hashes, row.id, hash))
                |> push_event("grid_output", %{
                  id: row.id,
                  html: IO.iodata_to_binary(html),
                  empty: ForemanWeb.AnsiHtml.blank?(excerpt)
                })
              end

            _ ->
              acc
          end
        end)

      ok? = Enum.all?(results, fn {_, result} -> match?({:ok, _}, result) end)

      {reader, effects} =
        GridReader.step(socket.assigns.grid_reader, if(ok?, do: :captured, else: :failed), %{})

      {connection, []} =
        Foreman.SessionsConnection.step(
          socket.assigns.connection,
          if(ok?, do: :read_ok, else: :read_failed),
          %{}
        )

      changed? = connection != socket.assigns.connection

      socket =
        assign(socket,
          grid_reader: reader,
          connection: connection,
          updated_at: if(ok?, do: DateTime.utc_now(), else: socket.assigns.updated_at)
        )

      socket = reader_effects(socket, effects)
      {:noreply, if(changed?, do: refresh(socket), else: socket)}
    end
  end

  defp skipped_lines(skipped) do
    skipped
    |> Enum.group_by(fn item ->
      case item.reason do
        reason when reason in ["session_ended", "window_gone", "not_registered"] ->
          "the pane is closed."

        "prompt_busy" ->
          "the agent is busy."

        "already_delivered" ->
          "the pane already received the note."

        _ ->
          "the terminal could not receive the note."
      end
    end)
    |> Enum.sort()
    |> Enum.map(fn {reason, items} ->
      "Not sent to #{Enum.map_join(items, ", ", & &1.name)}: #{reason}"
    end)
  end

  defp tmux_opts, do: Application.get_env(:foreman, :session_tree_tmux, [])

  defp note_form(text \\ "") do
    {%{text: text}, %{text: :string}} |> Ecto.Changeset.change() |> to_form(as: :note)
  end

  defp toggle(socket, field) do
    {next, []} = Foreman.Initiatives.Disclosure.step(socket.assigns[field], :toggle, %{})
    assign(socket, field, next)
  end

  defp check_connection(socket) do
    rows = Repo.all(from s in AgentSession, where: is_nil(s.ended_at))

    sockets =
      rows
      |> Enum.map(fn row ->
        if row.tmux_server == "board",
          do: Application.get_env(:foreman, :planning_tmux_socket, "foreman"),
          else: Application.get_env(:foreman, :external_tmux_socket, "default")
      end)
      |> Enum.uniq()

    ok? =
      Enum.all?(sockets, fn server ->
        match?({:ok, _}, Foreman.SessionTargets.list(Keyword.put(tmux_opts(), :socket, server)))
      end)

    {next, []} =
      Foreman.SessionsConnection.step(
        socket.assigns.connection,
        if(ok?, do: :read_ok, else: :read_failed),
        %{}
      )

    socket
    |> assign(
      connection: next,
      updated_at: if(ok?, do: DateTime.utc_now(), else: socket.assigns.updated_at)
    )
    |> refresh()
  end

  defp refresh(socket) do
    entries =
      Repo.all(AgentSession)
      |> Enum.map(fn row ->
        %{
          row: row,
          facts: AgentSessions.label_facts(row),
          cards: AgentSessions.open_cards(row.id)
        }
      end)

    tree = SessionTree.build(entries, show_ended: socket.assigns.ended == :expanded)

    rows =
      Enum.map(tree.rows, fn item ->
        if item.group,
          do: item,
          else:
            Map.merge(item, %{
              hidden:
                Enum.any?(
                  item.ancestors,
                  &(Map.get(socket.assigns.disclosures, &1) == :collapsed)
                ),
              collapsed: Map.get(socket.assigns.disclosures, item.id) == :collapsed,
              children_live:
                Enum.any?(entries, &(&1.row.parent_id == item.id and is_nil(&1.row.ended_at)))
            })
      end)

    grid =
      if socket.assigns.sessions_view == :grid do
        rows
        |> SessionGrid.build()
        |> Enum.map(fn item ->
          if item.group,
            do: item,
            else: Map.put(item, :title, Foreman.SessionHistory.title(item.row))
        end)
      else
        []
      end

    grid_rows = rows |> Enum.reject(& &1.group) |> Map.new(&{&1.id, &1.row})

    socket
    |> assign(
      grid_rows: grid_rows,
      grid_read_at: Map.take(socket.assigns.grid_read_at, Map.keys(grid_rows)),
      grid_hashes: Map.take(socket.assigns.grid_hashes, Map.keys(grid_rows)),
      total: Enum.count(rows, &(not &1.group)),
      working: Enum.count(rows, &(not &1.group and &1.view.label == "Working")),
      review: Enum.count(rows, &(not &1.group and &1.view.label == "In review")),
      ended_form:
        {%{ended: socket.assigns.ended == :expanded}, %{ended: :boolean}}
        |> Ecto.Changeset.change()
        |> to_form(as: :filter),
      ended_count: tree.ended_count,
      waiting_count: length(tree.waiting),
      coordinator_ids: entries |> Enum.reject(&(&1.row.kind == "build")) |> Enum.map(& &1.row.id)
    )
    |> stream(:grid_items, grid, reset: true)
    |> stream(:rows, rows, reset: true)
    |> stream(:waiting_rows, tree.waiting, reset: true)
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:sessions}
      repos={@repos}
      pending_count={@pending_count}
      drawer_state={@drawer_state}
      streams={@streams}
    >
      <div id="sessions-page" class="bb-sessions">
        <header class="flex flex-wrap items-center justify-between gap-3 mb-4">
          <h1 class="text-xl font-semibold">Sessions</h1>
          <div class="flex flex-wrap items-center gap-3">
            <button
              id="note-coordinators"
              class="bb-tbtn"
              phx-click="toggle-note"
              aria-expanded={to_string(@note == :expanded)}
            >
              Note to all coordinators
            </button>
            <span id="sessions-live-line" class="bb-sessions-online text-xs text-foreground-softer">
              <span class={[
                "bb-session-dot",
                @connection == :live && "bg-success",
                @connection == :tmux_error && "bg-warning",
                @connection == :connecting && "bg-sunken"
              ]}>
              </span>
              <%= case @connection do %>
                <% :connecting -> %>
                  Connecting…
                <% :live -> %>
                  Live · updated <ForemanWeb.TicketDetail.timestamp at={@updated_at} />
                <% :tmux_error -> %>
                  tmux does not answer · last read
                  <ForemanWeb.TicketDetail.timestamp at={@updated_at} />
              <% end %>
            </span>
            <span class="bb-sessions-offline text-xs text-foreground-softer">
              Not connected · updated <ForemanWeb.TicketDetail.timestamp at={@updated_at} />
            </span>
          </div>
        </header>
        <ForemanWeb.StatusLine.status_line
          id="sessions-disconnected"
          kind={:error}
          class="bb-sessions-offline mb-3"
        >
          Not connected to the board. Trying again…
          <a href="/sessions" class="bb-tbtn">Reload page</a>
        </ForemanWeb.StatusLine.status_line>
        <ForemanWeb.StatusLine.status_line
          :if={@connection == :tmux_error}
          id="sessions-tmux-error"
          kind={:error}
          class="mb-3"
        >
          Cannot read tmux. States can be out of date.
          <button id="sessions-retry" class="bb-tbtn" phx-click="retry" phx-disable-with="Trying…">
            Try again now
          </button>
        </ForemanWeb.StatusLine.status_line>
        <div
          id="sessions-content"
          class="bb-sessions-content"
          phx-disconnected={JS.set_attribute({"inert", ""})}
          phx-connected={JS.remove_attribute("inert")}
        >
          <.form
            :if={@note == :expanded}
            for={@note_form}
            id="coordinator-note-form"
            phx-submit="send-note"
            class="bb-panel mb-3 flex items-end gap-3"
          >
            <div class="flex-1">
              <.input
                field={@note_form[:text]}
                label="Note to all coordinators"
                class="w-full rounded-md border border-base bg-base px-3 py-2 text-sm focus:outline-primary"
                required
              />
            </div>
            <button
              id="send-coordinator-note"
              class="inline-flex shrink-0 whitespace-nowrap rounded-md bg-primary px-3 py-2 text-sm font-medium text-foreground-primary hover:opacity-90 transition-opacity"
              phx-disable-with="Sending…"
            >
              Send note
            </button>
          </.form>
          <%= case @result do %>
            <% {:note, count, skipped} -> %>
              <ForemanWeb.StatusLine.status_line id="note-result" kind={:success} class="mb-3">
                Sent to {count} {if count == 1, do: "coordinator", else: "coordinators"}.
              </ForemanWeb.StatusLine.status_line>
              <ForemanWeb.StatusLine.status_line
                :if={skipped != []}
                id="note-skipped"
                kind={:info}
                class="mb-3"
              >
                <p :for={line <- skipped_lines(skipped)}>{line}</p>
              </ForemanWeb.StatusLine.status_line>
            <% {kind, text} -> %>
              <ForemanWeb.StatusLine.status_line id="sessions-result" kind={kind} class="mb-3">
                {text}
              </ForemanWeb.StatusLine.status_line>
            <% _ -> %>
          <% end %>
          <div
            id="sessions-view-switch"
            class="bb-view-switch mb-3"
            role="group"
            aria-label="Sessions view"
          >
            <button
              :for={view <- [:tree, :grid]}
              id={"sessions-view-#{view}"}
              phx-click="sessions-view"
              phx-value-view={view}
              aria-pressed={to_string(@sessions_view == view)}
              class="bb-tbtn"
            >
              {if view == :tree, do: "Tree", else: "Grid"}
            </button>
          </div>
          <section :if={@waiting_count > 0} id="waiting-strip" class="mb-4">
            <h2 class="font-semibold mb-2">
              Waiting on you <span class="text-foreground-softer">{@waiting_count}</span>
            </h2>
            <div
              id="waiting-sessions"
              phx-update="stream"
              class={["bb-session-waiting", @waiting == :collapsed && "bb-session-waiting-capped"]}
            >
              <.link
                :for={{id, item} <- @streams.waiting_rows}
                id={id}
                navigate={item.href}
                class="bb-session-wait"
              >
                <span class="font-medium text-xs" title={item.action}>{item.action}</span>
                <span class="text-xs text-foreground-softer truncate">
                  {item.row.name} ·
                  <ForemanWeb.TicketDetail.timestamp at={
                    item.facts.card_at || item.row.state_at || item.row.started_at
                  } />
                </span>
              </.link>
            </div>
            <button
              :if={@waiting_count > 4}
              id="show-all-waiting"
              class={["bb-tbtn mt-2", @waiting_count <= 6 && "bb-session-show-all-narrow"]}
              phx-click="toggle-waiting"
            >
              {if @waiting == :collapsed, do: "Show all #{@waiting_count}", else: "Show fewer"}
            </button>
          </section>
          <section id="all-sessions" class="bb-panel bb-session-panel">
            <div class="flex flex-wrap justify-between items-center gap-2 p-4 border-b border-base">
              <h2 class="font-semibold">
                All sessions {@total}
                <span class="font-normal text-xs text-foreground-softer">
                  · {@working} working · {@review} in review
                </span>
              </h2>
              <.form
                for={@ended_form}
                id="show-ended-form"
                phx-change="toggle-ended"
                class="bb-session-filter"
              >
                <.input
                  type="checkbox"
                  class="size-4 cursor-pointer rounded border border-base accent-primary"
                  id="show-ended"
                  field={@ended_form[:ended]}
                  label={"Show ended (last 7 days) · #{@ended_count}"}
                />
              </.form>
            </div>
            <div :if={@connection == :connecting} id="sessions-loading" class="p-4">
              <p>Loading sessions…</p>
              <div id="sessions-grid-loading" hidden={@sessions_view != :grid}>
                <div :for={n <- 1..3} id={"grid-skeleton-#{n}"} class="bb-grid-skeleton">
                  <div :for={_ <- 1..4} class="h-32 bg-sunken rounded"></div>
                </div>
              </div>
              <div hidden={@sessions_view != :tree}>
                <div
                  :for={n <- 1..5}
                  class="h-8 my-2 bg-sunken rounded"
                  style={"margin-left: #{rem(n, 3) * 28}px"}
                >
                </div>
              </div>
            </div>
            <div
              :if={@total == 0 and @connection != :connecting}
              id="sessions-empty"
              class="m-4 p-8 border border-dashed border-base rounded-lg"
            >
              <h2 class="font-semibold">No sessions are running</h2>
              <p class="text-foreground-softer my-2">
                {if @ended == :expanded,
                  do: "No sessions ended in the last 7 days.",
                  else: "Coordinators and their builds show here while they run."}
              </p>
              <button
                id="start-main-coordinator"
                class="inline-flex whitespace-nowrap rounded-md bg-primary px-3 py-2 text-sm font-medium text-foreground-primary hover:opacity-90 transition-opacity"
                phx-click="start-main"
                phx-disable-with="Starting…"
              >
                Start main coordinator
              </button>
            </div>
            <div
              id="session-grid"
              phx-update="stream"
              hidden={@sessions_view != :grid or @connection == :connecting}
              class={["bb-session-grid", @connection == :tmux_error && "bb-grid-stale"]}
            >
              <div
                :for={{id, item} <- @streams.grid_items}
                id={id}
                class={if item.group, do: "bb-grid-heading", else: "bb-grid-cell"}
              >
                <%= if item.group do %>
                  <h3 class="text-sm font-semibold">{item.name}</h3>
                <% else %>
                  <SessionGrid.card item={item} connection={@connection} />
                <% end %>
              </div>
            </div>
            <div
              id="session-tree"
              phx-update="stream"
              hidden={@connection == :connecting or @sessions_view != :tree}
            >
              <div :for={{id, item} <- @streams.rows} id={id} hidden={!item.group && item.hidden}>
                <%= if item.group do %>
                  <div id="sessions-unassigned" class="bb-session-unassigned">
                    <strong>Unassigned</strong><span>The board knows these sessions but not the coordinator that started them.</span>
                  </div>
                <% else %>
                  <div
                    class={["bb-session-row", item.row.ended_at && "bb-session-ended"]}
                    style={"--session-depth: #{item.depth}"}
                  >
                    <.link
                      id={"session-link-#{item.id}"}
                      navigate={~p"/sessions/#{item.id}"}
                      class="bb-session-row-link"
                      aria-label={"Open #{item.row.name}"}
                    >
                      <span class="sr-only">Open {item.row.name}</span>
                    </.link>
                    <div class="bb-session-name">
                      <button
                        :if={item.row.kind != "build"}
                        id={"collapse-#{item.id}"}
                        class="bb-session-collapse"
                        phx-click="collapse"
                        phx-value-id={item.id}
                        aria-label={"Toggle #{item.row.name}"}
                        aria-expanded={to_string(!item.collapsed)}
                      >
                        <.icon
                          name={
                            if(item.collapsed, do: "hero-chevron-right", else: "hero-chevron-down")
                          }
                          class="size-3.5"
                        />
                      </button>
                      <span class="truncate font-mono text-xs" title={item.row.name}>
                        {item.row.name}
                      </span>
                      <span :if={item.row.kind != "build"} class="bb-session-kind">
                        {if item.row.kind == "main_coordinator", do: "main", else: "epic"}
                      </span>
                    </div>
                    <div
                      class="bb-session-ticket truncate font-mono text-xs text-foreground-softer"
                      title={
                        Enum.join(Enum.reject([item.row.ticket, item.row.branch], &is_nil/1), " · ")
                      }
                    >
                      {item.row.ticket} <span :if={item.row.branch}>· {item.row.branch}</span>
                    </div>
                    <div
                      class="bb-session-harness truncate text-xs text-foreground-softer"
                      title={"#{item.row.harness} · #{item.row.model}"}
                    >
                      {item.row.harness} · {item.row.model}
                    </div>
                    <div class="bb-session-state">
                      <SessionState.badge id={"tree-state-#{item.id}"} view={item.view} />
                      <span
                        :if={item.row.ended_at && item.children_live}
                        class="text-xs text-foreground-softer"
                      >
                        Its builds still run
                      </span>
                      <.icon
                        :if={item.facts.parent_ended_at}
                        name="hero-exclamation-triangle"
                        class="size-3.5 text-warning"
                      />
                    </div>
                    <button
                      id={"focus-#{item.id}"}
                      class="bb-iconbtn bb-session-focus"
                      phx-click="focus"
                      phx-value-id={item.id}
                      disabled={item.row.ended_at != nil or @connection == :tmux_error}
                      title={
                        cond do
                          @connection == :tmux_error -> "tmux does not answer"
                          item.row.ended_at -> "The pane is closed"
                          true -> "Focus terminal"
                        end
                      }
                      aria-label={"Focus #{item.row.name}"}
                    >
                      <.icon name="hero-command-line" class="size-4" />
                    </button>
                  </div>
                <% end %>
              </div>
            </div>
          </section>
        </div>
        <SessionGrid.observer />
        <div
          id="session-collapse-storage"
          phx-hook=".SessionCollapse"
          phx-update="ignore"
          data-ids={Jason.encode!(@coordinator_ids)}
        >
        </div>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".SessionCollapse">
          export default {
            mounted() {
              try {
                const ids = JSON.parse(this.el.dataset.ids).filter(id => localStorage.getItem(`foreman:session-collapsed:${id}`) === "true")
                this.pushEvent("restore-collapse", {ids})
              } catch (_) {}
              this.handleEvent("save-collapse", ({id, collapsed}) => {
                try { localStorage.setItem(`foreman:session-collapsed:${id}`, String(collapsed)) } catch (_) {}
              })
            }
          }
        </script>
      </div>
    </Layouts.app>
    """
  end
end
