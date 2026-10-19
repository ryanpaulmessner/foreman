defmodule ForemanWeb.TicketDetail do
  use ForemanWeb, :html
  import Phoenix.LiveView, only: [stream: 4, push_patch: 2]
  alias Fluxon.Components.{Sheet, Badge, Tabs}

  def load(socket, params, uri) do
    key = Foreman.TicketSheet.key(params["ticket"])
    ticket = key && Foreman.Drilldown.ticket(key)

    ticket =
      if ticket,
        do:
          Map.merge(ticket, %{
            launchable: Foreman.Sessions.launchable?(Foreman.Sessions.target(key)),
            planning_session: Foreman.Sessions.get(key),
            files?:
              Enum.any?(
                Foreman.RuntimeState.repos(),
                &(&1["key"] == ticket.repo and &1["tickets"] == "files")
              )
          }),
        else: nil

    {state, []} =
      Foreman.TicketSheet.step(
        Map.get(socket.assigns, :sheet_state, :closed),
        {:params, %{ticket: ticket}},
        %{}
      )

    socket
    |> assign(
      ticket:
        ticket &&
          ticket
          |> Map.drop([:history, :sessions, :notes])
          |> Map.put(:preview, Foreman.Previews.for_ticket(key)),
      ticket_key: key,
      sheet_state: state,
      ticket_tab: Foreman.TicketSheet.tab(params["tab"]),
      page_uri: uri,
      sheet_return: Foreman.TicketSheet.path(uri)
    )
    |> stream(:ticket_history, if(ticket, do: ticket.history, else: []), reset: true)
    |> stream(:ticket_sessions, if(ticket, do: ticket.sessions, else: []), reset: true)
    |> stream(:ticket_notes, if(ticket, do: ticket.notes, else: []), reset: true)
    |> stream(:ticket_requests, if(ticket, do: Foreman.Requests.for_ticket(key), else: []),
      reset: true
    )
  end

  def refresh(socket) do
    uri = socket.assigns.page_uri
    load(socket, URI.decode_query(URI.parse(uri).query || ""), uri)
  end

  def close(socket, %{"key" => key}) do
    current = socket.assigns.ticket_key

    if current && key == elem(current, 0) <> ":" <> elem(current, 1),
      do: push_patch(socket, to: socket.assigns.sheet_return),
      else: socket
  end

  def preview(socket, %{"action" => action}) do
    key = socket.assigns.ticket_key

    result =
      case {action, key && Foreman.Previews.for_ticket(key)} do
        {"start", preview} when not is_nil(preview) -> Foreman.Previews.start(key)
        {"stop", %{id: id}} when not is_nil(id) -> Foreman.Previews.stop(id)
        _ -> {:error, :unavailable}
      end

    socket =
      case result do
        {:ok, _} -> socket
        {:error, reason} -> Phoenix.LiveView.put_flash(socket, :error, "Preview: #{reason}")
      end

    refresh(socket)
  end

  attr :ticket, :any, required: true
  attr :state, :atom, required: true
  attr :return_to, :string, required: true
  attr :streams, :map, required: true
  attr :tab, :string, required: true
  attr :uri, :string, required: true

  def sheet(assigns) do
    ~H"""
    <Sheet.sheet
      id="ticket-sheet"
      open={@state == :open}
      placement="right"
      class="w-[min(760px,100vw)] space-y-6 [scrollbar-gutter:stable]"
      hide_close_button
      on_close={
        JS.push("close-ticket",
          value: %{key: if(@ticket, do: @ticket.repo <> ":" <> @ticket.id, else: "")}
        )
      }
    >
      <.content
        :if={@ticket}
        ticket={@ticket}
        return_to={@return_to}
        streams={@streams}
        tab={@tab}
        uri={@uri}
      />
    </Sheet.sheet>
    """
  end

  attr :ticket, :any, required: true
  attr :return_to, :string, required: true
  attr :streams, :map, required: true
  attr :tab, :string, required: true
  attr :uri, :string, required: true

  @doc "The ticket's header and tabs, shown in the ticket sheet or the Needs you side panel."
  def content(assigns) do
    ~H"""
    <header class="space-y-3">
      <div class="flex items-center gap-3 text-xs text-foreground-softer">
        <span>{@ticket.repo}</span><span>/</span><span class="font-mono">{@ticket.id}</span>
        <.link
          id="ticket-close"
          patch={@return_to}
          class="ml-auto rounded p-2 hover:bg-sunken"
          aria-label="Close ticket"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </.link>
      </div>
      <h2
        id="ticket-title"
        class="text-xl font-semibold text-foreground"
        phx-mounted={
          JS.set_attribute({"aria-labelledby", "ticket-title"}, to: "#ticket-sheet [role=dialog]")
        }
      >
        {@ticket.raw["title"] || @ticket.id}
      </h2>
      <div class="flex flex-wrap gap-2">
        <span id="ticket-stage">
          <Badge.badge color="info">{@ticket.stage}</Badge.badge>
        </span>
        <Badge.badge id="ticket-status">
          {if !@ticket.files?, do: "bd: "}{@ticket.raw["status"] ||
            "unavailable"}
        </Badge.badge>
        <Badge.badge :if={@ticket.raw["acceptance_progress"]} id="ticket-acceptance-progress">
          Acceptance {@ticket.raw["acceptance_progress"]["checked"]}/{@ticket.raw[
            "acceptance_progress"
          ]["total"]}
        </Badge.badge>
        <Badge.badge>{@ticket.raw["issue_type"] || "ticket"}</Badge.badge>
        <Badge.badge :if={@ticket.raw["priority"] != nil}>P{@ticket.raw["priority"]}</Badge.badge>
      </div>
      <ForemanWeb.PreviewControls.controls
        :if={@ticket.preview}
        preview={@ticket.preview}
        terminal={@ticket.stage in [:merged, :done, :abandoned, "merged", "done", "abandoned"]}
      />
      <div id="ticket-actions" class="flex flex-wrap gap-2">
        <ForemanWeb.PlanningSession.launch_button
          id="ticket-launch"
          key={@ticket.key}
          allowed={@ticket.launchable}
          session={@ticket.planning_session}
        />
        <code
          :if={@ticket.close_suggested}
          id="ticket-close-suggestion"
          class="rounded border border-base px-3 py-2 text-xs"
        >
          bd close {@ticket.id}
        </code>
      </div>
    </header>
    <ForemanWeb.PlanningSession.status id="ticket" session={@ticket.planning_session} />
    <Tabs.tabs id="ticket-tabs">
      <Tabs.tabs_list
        active_tab={"ticket-" <> @tab}
        size="xs"
        class="max-w-full gap-x-3 overflow-x-auto sm:gap-x-4"
      >
        <:tab
          :for={
            {key, label} <- [
              {"overview", "Overview"},
              {"history", "Stage history"},
              {"sessions", "Sessions"},
              {"notes", "Agent notes"},
              {"requests", "Requests"}
            ]
          }
          name={"ticket-" <> key}
          class="shrink-0 whitespace-nowrap"
          phx-click={JS.patch(Foreman.TicketSheet.tab_path(@uri, key))}
        >
          <span class="sm:hidden">
            {if key == "history",
              do: "History",
              else: if(key == "notes", do: "Notes", else: label)}
          </span>
          <span class="hidden sm:inline">{label}</span>
        </:tab>
      </Tabs.tabs_list>
      <Tabs.tabs_panel name="ticket-requests" active={@tab == "requests"} class="pt-5">
        <div id="ticket-requests" phx-update="stream" class="space-y-3">
          <ForemanWeb.RequestCard.summary
            :for={{id, request} <- @streams.ticket_requests}
            id={id}
            request={request}
          />
        </div>
      </Tabs.tabs_panel>
      <Tabs.tabs_panel name="ticket-overview" active={@tab == "overview"} class="pt-5">
        <section id="ticket-overview" class="space-y-5">
          <div
            :for={
              {key, title} <- [
                {"description", "Description"},
                {"acceptance_criteria", "Acceptance"},
                {"design", "Design"},
                {"notes", "Beads notes"}
              ]
            }
            :if={@ticket.raw[key] not in [nil, ""]}
          >
            <h3 class="bb-label mb-2">{title}</h3>
            <div class="fm-markdown">
              {Phoenix.HTML.raw(Foreman.Markdown.render(@ticket.raw[key], repo: @ticket.repo))}
            </div>
          </div>
          <div :if={@ticket.raw["dependencies"] not in [nil, []]}>
            <h3 class="bb-label mb-2">Dependencies</h3>
            <div class="flex flex-wrap gap-2">
              <span
                :for={dep <- @ticket.raw["dependencies"] || []}
                class="rounded border border-base px-2 py-1 text-xs"
              >
                {dep["type"]} · {dep["depends_on_id"]}
              </span>
            </div>
          </div>
          <div :if={@ticket.dependents != []}>
            <h3 class="bb-label mb-2">Dependents</h3>
            <div class="flex flex-wrap gap-2">
              <span
                :for={dep <- @ticket.dependents}
                class="rounded border border-base px-2 py-1 text-xs"
              >
                {dep.type} · {elem(dep.key, 1)}
              </span>
            </div>
          </div>
          <div :if={@ticket.attachments != []}>
            <h3 class="bb-label mb-2">Attached epics</h3>
            <.link
              :for={epic <- @ticket.attachments}
              navigate={~p"/epics/#{epic.repo}/#{epic.id}"}
              class="mr-2 font-mono text-xs hover:underline"
            >
              {epic.repo}:{epic.id}
            </.link>
          </div>
          <div class="rounded-lg border border-base p-4">
            <h3 class="bb-label mb-3">Allowed next events</h3>
            <div id="ticket-allowed" class="flex flex-wrap gap-2">
              <Badge.badge :for={event <- @ticket.allowed}>{event}</Badge.badge>
            </div>
          </div>
          <div :if={@ticket.change_requests != []}>
            <h3 class="bb-label mb-2">Linked CRs</h3>
            <div id="ticket-crs" class="flex gap-2">
              <a
                :for={cr <- @ticket.change_requests}
                href={cr["url"]}
                target="_blank"
                rel="noopener noreferrer"
                class="hover:underline"
                title={cr["title"]}
              >
                <Badge.badge>#{cr["number"]} · {cr["state"]}</Badge.badge>
              </a>
            </div>
          </div>
          <div :if={extra_fields(@ticket.raw) != []}>
            <h3 class="bb-label mb-3">
              {if @ticket.raw["acceptance_progress"], do: "Ticket fields", else: "Beads fields"}
            </h3>
            <dl class="grid grid-cols-[120px_minmax(0,1fr)] gap-2 text-xs">
              <%= for {key, value} <- extra_fields(@ticket.raw) do %>
                <dt class="text-foreground-softer">{String.replace(key, "_", " ")}</dt>
                <dd class="break-words">
                  <%= if @ticket.raw["acceptance_progress"] && key in ~w(created_at closed_at) do %>
                    <.timestamp at={value} />
                  <% else %>
                    <span class="whitespace-pre-wrap">{value_text(value)}</span>
                  <% end %>
                </dd>
              <% end %>
            </dl>
          </div>
          <div :if={@ticket.overlay}>
            <h3 class="bb-label mb-3">Overlay</h3>
            <dl class="grid grid-cols-[120px_minmax(0,1fr)] gap-2 text-xs">
              <dt>Stage changed</dt>
              <dd><.timestamp at={@ticket.overlay.stage_changed_at} /></dd>
              <dt :if={@ticket.overlay.orphaned_at}>Orphaned</dt>
              <dd :if={@ticket.overlay.orphaned_at}>
                <.timestamp at={@ticket.overlay.orphaned_at} />
              </dd>
            </dl>
          </div>
        </section>
      </Tabs.tabs_panel>
      <Tabs.tabs_panel name="ticket-history" active={@tab == "history"} class="pt-5">
        <section id="ticket-history-section">
          <div id="ticket-history" phx-update="stream">
            <.history_row
              :for={{id, event} <- @streams.ticket_history}
              id={id}
              event={event}
              repo={@ticket.repo}
            />
          </div>
        </section>
      </Tabs.tabs_panel>
      <Tabs.tabs_panel name="ticket-sessions" active={@tab == "sessions"} class="pt-5">
        <section id="ticket-sessions-section">
          <div id="ticket-sessions" phx-update="stream" class="space-y-3">
            <article
              :for={{id, session} <- @streams.ticket_sessions}
              id={id}
              class="rounded-lg border border-base p-4"
            >
              <h4 class="font-mono font-medium">{session.window}</h4>
              <dl class="mt-3 grid grid-cols-[100px_minmax(0,1fr)] gap-2 text-xs">
                <dt>Started</dt>
                <dd><.timestamp at={session.started_at} /></dd>
                <dt>Last seen</dt>
                <dd><.timestamp at={session.last_seen_at} /></dd>
                <dt>Ended</dt>
                <dd><.timestamp at={session.ended_at} /></dd>
                <%= for {key, value} <- Enum.sort(session.details) do %>
                  <dt class="text-foreground-softer">{key}</dt>
                  <dd class="break-all">{value_text(value)}</dd>
                <% end %>
              </dl>
            </article>
          </div>
        </section>
      </Tabs.tabs_panel>
      <Tabs.tabs_panel name="ticket-notes" active={@tab == "notes"} class="pt-5">
        <section id="ticket-notes-section">
          <div id="ticket-notes" phx-update="stream" class="space-y-3">
            <article
              :for={{id, note} <- @streams.ticket_notes}
              id={id}
              class="rounded-lg border border-base p-4"
            >
              <div class="mb-2 flex flex-wrap gap-2 text-xs">
                <Badge.badge>{note.kind}</Badge.badge>
                <span>{note.actor}</span><span class="ml-auto text-foreground-softer"><.timestamp at={
                  note.inserted_at
                } /></span>
              </div>
              <div class="fm-markdown">
                {Phoenix.HTML.raw(Foreman.Markdown.render(note.body, repo: @ticket.repo))}
              </div>
            </article>
          </div>
        </section>
      </Tabs.tabs_panel>
    </Tabs.tabs>
    """
  end

  attr :id, :string, required: true
  attr :event, :map, required: true
  attr :repo, :string, required: true

  def history_row(assigns) do
    assigns = assign(assigns, :payload, history_payload(assigns.event))

    ~H"""
    <article id={@id} data-outcome={@event.outcome} class="border-b border-base py-3 text-xs">
      <div class="flex flex-wrap items-center gap-2">
        <span class="font-mono font-medium">{@event.event}</span>
        <span>{@event.from_stage || "—"} → {@event.to_stage}</span>
        <Badge.badge :if={@event.outcome == "invalid"} color="danger" data-history-outcome="refused">
          Refused
        </Badge.badge>
      </div>
      <div class="mt-1 text-foreground-softer">
        {@event.actor} · <.timestamp at={@event.inserted_at} />
      </div>
      <dl :if={@payload != []} class="mt-2 grid grid-cols-[90px_minmax(0,1fr)] gap-2">
        <%= for {key, value} <- @payload do %>
          <dt class="text-foreground-softer">{key}</dt>
          <dd class="whitespace-pre-wrap break-words">
            <%= if key in ["Brief", "Report", "Spec", "Path"] do %>
              <.document_link repo={@repo} path={value} />
            <% else %>
              {value_text(value)}
            <% end %>
          </dd>
        <% end %>
      </dl>
    </article>
    """
  end

  attr :repo, :string, required: true
  attr :path, :string, required: true

  def document_link(assigns) do
    uri = URI.parse(assigns.path)

    target =
      if uri.scheme in ["http", "https"],
        do: assigns.path,
        else: Foreman.Markdown.viewer_path(assigns.repo, assigns.path)

    assigns = assign(assigns, :target, target)

    ~H"""
    <.link
      navigate={@target}
      class="break-words font-mono text-xs underline decoration-current/30 underline-offset-4 hover:decoration-current"
    >
      {@path}
    </.link>
    """
  end

  attr :at, :any, required: true

  def timestamp(assigns) do
    time =
      case assigns.at do
        %NaiveDateTime{} = time ->
          DateTime.from_naive!(time, "Etc/UTC")

        %DateTime{} = time ->
          time

        text when is_binary(text) ->
          case DateTime.from_iso8601(text) do
            {:ok, time, _} -> time
            _ -> nil
          end

        nil ->
          nil
      end

    assigns =
      assign(assigns,
        full: time && DateTime.to_iso8601(time),
        relative: time && ForemanWeb.RelativeTime.format(time)
      )

    ~H"""
    <time :if={@full} datetime={@full} title={@full}>{@relative}</time><span :if={is_nil(@full)}>—</span>
    """
  end

  defp history_payload(event) do
    [
      {"title", "Title"},
      {"window", "Session"},
      {"branch", "Branch"},
      {"brief", "Brief"},
      {"brief_path", "Brief"},
      {"report", "Report"},
      {"report_path", "Report"},
      {"path", if(event.event == "report", do: "Report", else: "Path")},
      {"spec_link", "Spec"},
      {"spec_path", "Spec"},
      {"spec", "Spec"},
      {"beads_epic_id", "Epic"},
      {"body", "Body"}
    ]
    |> Enum.flat_map(fn {key, label} ->
      case event.payload[key] do
        value when is_binary(value) and value != "" -> [{label, value}]
        _ -> []
      end
    end)
  end

  defp extra_fields(raw),
    do:
      raw
      |> Map.drop(
        ~w(id title status issue_type priority description acceptance_criteria acceptance_progress design notes dependencies)
      )
      |> Enum.reject(fn {_key, value} -> value in [nil, [], ""] end)
      |> Enum.sort()

  defp value_text(v) when is_binary(v), do: v
  defp value_text(v), do: Jason.encode!(v)
end
