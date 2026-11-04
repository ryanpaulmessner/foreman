defmodule ForemanWeb.NeedsYouLive do
  use ForemanWeb, :live_view
  alias Foreman.Requests
  alias Fluxon.Components.{Button, Badge}
  alias ForemanWeb.CardItems

  @cards [
    stream: :pending,
    ui: :card_ui,
    footers: :card_footers,
    headings: :pending_headings,
    prefix: ""
  ]

  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :reconcile, 3_000)

    {:ok,
     socket
     |> assign(:pending_ids, MapSet.new())
     |> assign(:pending_versions, %{})
     |> assign(:pending_headings, MapSet.new())
     |> ForemanWeb.CardItems.assigns(@cards)
     |> assign(panel: Foreman.CardPanel.__fsm__(:initial), panel_doc: nil, card_repos: [])
     |> stream_configure(:pending, dom_id: &("request-" <> &1.id))
     |> stream(:pending, [])
     |> refresh()}
  end

  def handle_params(params, uri, socket),
    do: {:noreply, socket |> ForemanWeb.TicketDetail.load(params, uri) |> panel(params)}

  defp panel(socket, params) do
    {event, doc} =
      cond do
        socket.assigns.sheet_state == :open -> {:ticket, nil}
        key = Foreman.CardPanel.doc_key(params["doc"]) -> panel_document(key)
        true -> {:close, nil}
      end

    {panel, []} = Foreman.CardPanel.step(socket.assigns.panel, event, %{})
    assign(socket, panel: panel, panel_doc: doc)
  end

  # A ticket open in the panel can vanish on refresh; the document is left as read.
  defp refresh_panel(%{assigns: %{panel: :ticket, sheet_state: state}} = socket)
       when state != :open,
       do: panel(socket, URI.decode_query(URI.parse(socket.assigns.page_uri).query || ""))

  defp refresh_panel(socket), do: socket

  defp panel_document({repo_key, path}) do
    repo = Enum.find(Foreman.CardText.repos(), &(&1["key"] == repo_key))

    case repo && Foreman.Documents.open(repo, path) do
      {:ok, doc} ->
        html =
          Foreman.Markdown.render(doc.content, repo: repo_key, path: doc.path, header_ids: false)

        {:document, %{repo: repo_key, path: doc.path, html: html}}

      _ ->
        {:missing, %{repo: repo_key, path: path}}
    end
  end

  def handle_event("resolve", params, socket) do
    outcome = resolve(params)
    {:noreply, socket |> CardItems.sent(@cards, params, outcome) |> result(outcome)}
  end

  def handle_event("resolve-panel", params, socket),
    do: {:noreply, CardItems.toggle(socket, @cards, params)}

  def handle_event("resolve-text", params, socket),
    do: {:noreply, CardItems.text(socket, @cards, params)}

  # Document links on cards and in the panel open in the side panel; the hook
  # leaves modified clicks (new tab) to the browser, which opens the viewer.
  def handle_event("open-doc", %{"href" => href}, socket) do
    case Foreman.CardPanel.doc_param(href) do
      nil ->
        {:noreply, socket}

      doc ->
        {:noreply, push_patch(socket, to: "/needs-you?" <> URI.encode_query(%{"doc" => doc}))}
    end
  end

  def handle_event("close-panel", _, socket) do
    if socket.assigns.panel == :closed,
      do: {:noreply, socket},
      else: {:noreply, push_patch(socket, to: "/needs-you")}
  end

  def handle_event("close-ticket", params, socket),
    do: {:noreply, ForemanWeb.TicketDetail.close(socket, params)}

  def handle_event("ticket-priority", params, socket),
    do:
      {:noreply,
       socket
       |> ForemanWeb.TicketDetail.priority(params)
       |> refresh()
       |> ForemanWeb.TicketDetail.refresh()}

  def handle_event("ticket-jump", params, socket),
    do:
      {:noreply,
       socket
       |> ForemanWeb.TicketDetail.jump(params)
       |> refresh()
       |> ForemanWeb.TicketDetail.refresh()}

  @doc "Resolves a shared request form, regardless of its page or drawer location."
  def resolve(%{"id" => id, "action" => "batch-answer"} = params) do
    ids = get_in(params, ["batch", "items"]) || []
    Requests.resolve(id, :answer, %{"answer" => ids})
  end

  def resolve(%{"id" => id, "decision" => params, "action" => "answer"}) do
    answer = if params["choice"] in [nil, ""], do: params["note"], else: params["choice"]

    Requests.resolve(id, :answer, %{
      "answer" => answer,
      "note" => params["note"],
      "image_comments" => params["image_comments"],
      "always" => params["always"] in [true, "true"]
    })
  end

  def resolve(%{"id" => id, "decision" => params, "action" => action})
      when action in ["approve", "decline"] do
    event = if action == "approve", do: :approve, else: :decline

    case Requests.resolve(id, event, %{"note" => params["note"]}) do
      {:error, :confirmation_required} ->
        request = Requests.get(id)
        query = URI.encode_query(%{"project" => request.repo_key, "request" => id})
        {:navigate, "/pull-requests?" <> query}

      outcome ->
        outcome
    end
  end

  def resolve(%{
        "id" => id,
        "action" => "wrong-question",
        "wrong_question" => %{"reason" => reason}
      }),
      do: Requests.resolve(id, :wrong_question, %{"note" => reason})

  def resolve(%{"id" => id, "action" => "withdraw", "withdraw" => %{"reason" => reason}}),
    do: Requests.withdraw_from_card(id, reason)

  def resolve(%{"id" => id, "action" => "go-session"}) do
    with request when not is_nil(request) <- Requests.get(id),
         source when not is_nil(source) <- Foreman.RequestSource.for_request(request) do
      case card(id, Foreman.RequestSource.focus(source)) do
        {:card, ^id, state} -> {:card, id, {:focus, state}}
        error -> error
      end
    else
      _ -> {:error, :source_unknown}
    end
  end

  def resolve(%{"id" => id, "action" => "card-question", "card_question" => %{"text" => text}}) do
    case Foreman.CardMessages.ask(id, text) do
      {:ok, message} -> {:ok, message}
      {:error, "refused in preview"} -> question_result(id, {:error, :tmux_unavailable}, text)
      {:error, :source_unknown} -> question_result(id, {:error, :window_gone}, text)
      error -> question_result(id, error, text)
    end
  end

  def resolve(%{"id" => id, "action" => "complete"}), do: Requests.resolve(id, :complete, %{})

  def resolve(%{"id" => id, "action" => "continue"}), do: Foreman.SessionWaiting.continue(id)

  def resolve(%{"id" => id, "action" => "open"}),
    do: card(id, Foreman.SessionWaiting.open(id))

  def resolve(%{"id" => id, "action" => "reply", "reply" => %{"text" => text}}) do
    case Foreman.SessionWaiting.reply(id, {:text, text}) do
      {:ok, request} -> {:ok, request}
      error -> card(id, error)
    end
  end

  def resolve(%{"id" => id, "action" => "reply", "reply" => %{"choice" => choice} = reply}) do
    choice =
      case {choice, Integer.parse(choice)} do
        {"other", _} -> {:other, reply["other"] || ""}
        {_, {index, ""}} -> {:option, index}
        _ -> :invalid
      end

    case Foreman.SessionWaiting.reply(id, choice) do
      {:ok, request} -> {:ok, request}
      error -> card(id, error)
    end
  end

  def resolve(_), do: {:error, :invalid_action}

  defp question_result(id, result, text) do
    case card(id, result) do
      {:card, ^id, state} -> {:card, id, {:question, {state, text}}}
      error -> error
    end
  end

  # Session results the card explains itself; anything else is "Request not updated".
  defp card(id, result) do
    event =
      case result do
        :ok ->
          :opened

        {:error, :no_client} ->
          :no_client

        {:error, reason}
        when reason in [:window_gone, :prompt_changed, :prompt_busy, :tmux_unavailable] ->
          reason

        _ ->
          nil
      end

    case event && Foreman.WaitingCard.step(:ready, event, %{}) do
      {state, []} -> {:card, id, state}
      _ -> if match?({:error, _}, result), do: result, else: {:error, :invalid}
    end
  end

  def grouped(pending) do
    keys = pending |> Enum.map(&{&1.repo_key, &1.bead_id}) |> Enum.uniq()
    groups = Enum.group_by(pending, &{&1.repo_key, &1.bead_id})

    Enum.flat_map(keys, fn key ->
      groups[key]
      |> Enum.with_index()
      |> Enum.map(fn {request, index} ->
        %{id: request.id, request: request, heading: index == 0}
      end)
    end)
  end

  def handle_info(:reconcile, socket) do
    Process.send_after(self(), :reconcile, 3_000)
    {:noreply, socket |> refresh() |> ForemanWeb.TicketDetail.refresh() |> refresh_panel()}
  end

  def handle_info({:notification, :foreman_events, _}, socket),
    do: {:noreply, socket |> refresh() |> ForemanWeb.TicketDetail.refresh() |> refresh_panel()}

  defp result(socket, {:navigate, path}), do: push_navigate(socket, to: path)

  defp result(socket, {:card, id, card}) do
    if MapSet.member?(socket.assigns.pending_ids, id) and
         match?(%{state: "pending"}, Requests.get(id)),
       do: CardItems.notice(socket, @cards, id, card),
       else: refresh(socket)
  end

  defp result(socket, {:ok, _}), do: refresh(socket)

  defp result(socket, {:error, _}),
    do: socket |> put_flash(:error, "Request not updated") |> refresh()

  defp refresh(socket) do
    pending = Requests.pending()
    ids = MapSet.new(pending, & &1.id)
    socket = assign(socket, :card_repos, Foreman.CardText.repos())
    previous = socket.assigns.pending_ids
    items = CardItems.with_state(socket, @cards, grouped(pending))
    messages = Foreman.CardMessages.versions(MapSet.to_list(ids))
    versions = Map.new(pending, &{&1.id, {messages[&1.id], &1.edited_at, &1.similar_question}})
    headings = items |> Enum.filter(& &1.heading) |> MapSet.new(& &1.id)

    # Leave unchanged cards mounted so polling does not erase an answer in progress.
    socket =
      Enum.reduce(MapSet.difference(previous, ids), socket, fn id, socket ->
        stream_delete_by_dom_id(socket, :pending, "request-" <> id)
      end)

    socket =
      items
      |> Enum.with_index()
      |> Enum.reduce(socket, fn {item, index}, socket ->
        if MapSet.member?(previous, item.id) and
             MapSet.member?(socket.assigns.pending_headings, item.id) == item.heading and
             socket.assigns.pending_versions[item.id] == versions[item.id],
           do: socket,
           else: stream_insert(socket, :pending, item, at: index)
      end)

    socket
    |> CardItems.prune(@cards, ids)
    |> assign(:pending_ids, ids)
    |> assign(:pending_versions, versions)
    |> assign(:pending_headings, headings)
    |> ForemanWeb.RequestCount.refresh()
    |> stream(:recent, Requests.recent(), reset: true)
    |> merge_list()
  end

  defp merge_list(socket) do
    prs = Foreman.WaitingWithoutCard.list()

    socket
    |> assign(:merge_count, length(prs))
    |> stream(:merge_list, prs, reset: true)
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      drawer_state={@drawer_state}
      drawer_error={@drawer_error}
      streams={@streams}
      flash={@flash}
      pending_count={@pending_count}
      active={:needs_you}
    >
      <div
        id="needs-you"
        phx-hook=".CardDocLinks"
        class={[
          "min-w-0",
          @panel != :closed &&
            "lg:grid lg:grid-cols-[minmax(0,48rem)_minmax(24rem,1fr)] lg:items-start lg:gap-6"
        ]}
      >
        <div class="min-w-0 space-y-5">
          <header id="inbox-heading" class="flex items-center gap-3">
            <h1 class="text-xl font-semibold">Needs you</h1>
            <Badge.badge :if={@pending_count > 0}>{@pending_count}</Badge.badge>
          </header>
          <div id="pending-requests" phx-update="stream" class="max-w-3xl space-y-5">
            <div
              id="inbox-empty"
              class="hidden only:block rounded-xl border border-dashed border-base p-10 text-center text-foreground-softer"
            >
              No pending requests
            </div>
            <.request_card
              :for={{id, item} <- @streams.pending}
              id={id}
              item={item}
              repos={@card_repos}
            />
          </div>
          <section
            :if={@merge_count > 0}
            id="merge-list-section"
            class="max-w-3xl space-y-3 border-t border-base pt-5"
            aria-labelledby="merge-list-heading"
          >
            <h2 id="merge-list-heading" class="flex items-center gap-2 text-base font-semibold">
              Pull requests for you to merge
              <Badge.badge>{@merge_count}</Badge.badge>
            </h2>
            <ul
              id="merge-list"
              phx-update="stream"
              class="divide-y divide-base rounded-xl border border-base"
            >
              <li
                :for={{id, pr} <- @streams.merge_list}
                id={id}
                class="flex items-center gap-3 px-4 py-3 text-sm"
              >
                <div class="flex min-w-0 flex-1 flex-wrap items-center gap-x-3 gap-y-1">
                  <span class="text-xs text-foreground-softer">{pr.repo_key}</span>
                  <span class="font-mono text-xs text-foreground-softer">#{pr.number}</span>
                  <span class="min-w-0 flex-1 basis-40 truncate font-medium" title={pr.title}>
                    {pr.title}
                  </span>
                  <span class="flex flex-wrap items-center gap-1">
                    <Badge.badge :for={bead_id <- pr.bead_ids} color="info" class="font-mono">
                      {bead_id}
                    </Badge.badge>
                  </span>
                  <span class="text-xs whitespace-nowrap text-foreground-softer">
                    <ForemanWeb.TicketDetail.timestamp at={pr.opened_at} />
                  </span>
                </div>
                <Button.button
                  id={"merge-open-#{pr.repo_key}-#{pr.number}"}
                  href={pr.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  variant="outline"
                  size="sm"
                  class="shrink-0"
                >
                  Open on GitHub <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
                </Button.button>
              </li>
            </ul>
          </section>
          <details
            id="recent-outcomes"
            class="max-w-3xl border-t border-base pt-4"
            phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
          >
            <summary class="cursor-pointer text-sm font-medium text-foreground-softer">
              Recent outcomes
            </summary>
            <div id="recent-requests" phx-update="stream" class="mt-4 space-y-3">
              <ForemanWeb.RequestCard.summary
                :for={{id, request} <- @streams.recent}
                id={id}
                request={request}
                repos={@card_repos}
                link={:patch}
              />
            </div>
          </details>
        </div>
        <button
          :if={@panel != :closed}
          id="card-panel-scrim"
          type="button"
          tabindex="-1"
          aria-label={if(@panel == :ticket, do: "Close ticket", else: "Close document")}
          phx-click="close-panel"
          class="bb-scrim lg:hidden"
        />
        <aside
          :if={@panel != :closed}
          id="card-panel"
          aria-label={if(@panel == :ticket, do: "Ticket", else: "Document")}
          phx-window-keydown="close-panel"
          phx-key="Escape"
          class="bb-sheet space-y-6 lg:sticky lg:top-6 lg:max-h-[calc(100vh-3rem)] lg:overflow-y-auto lg:rounded-xl lg:border lg:border-base lg:bg-base lg:p-6 lg:shadow-sm"
        >
          <%= if @panel == :ticket do %>
            <ForemanWeb.TicketDetail.content
              ticket={@ticket}
              return_to={@sheet_return}
              streams={@streams}
              tab={@ticket_tab}
              uri={@page_uri}
            />
          <% else %>
            <header class="flex items-center gap-3 text-xs text-foreground-softer">
              <span>{@panel_doc.repo}</span>
              <ForemanWeb.LongText.path
                text={@panel_doc.path}
                title={@panel_doc.path}
                class="min-w-0 flex-1 font-mono"
              />
              <a
                :if={@panel == :document}
                id="panel-open-viewer"
                data-viewer
                href={Foreman.Markdown.viewer_path(@panel_doc.repo, @panel_doc.path)}
                class="rounded p-2 hover:bg-sunken"
                aria-label="Open in Documents"
                title="Open in Documents"
              >
                <.icon name="hero-arrow-top-right-on-square" class="size-5" />
              </a>
              <.link
                id="panel-close"
                patch="/needs-you"
                class="rounded p-2 hover:bg-sunken"
                aria-label="Close document"
              >
                <.icon name="hero-x-mark" class="size-5" />
              </.link>
            </header>
            <div :if={@panel == :document} id="panel-document" class="fm-markdown">
              {Phoenix.HTML.raw(@panel_doc.html)}
            </div>
            <p :if={@panel == :unavailable} id="panel-status" class="py-6 text-foreground-softer">
              Document unavailable
            </p>
          <% end %>
        </aside>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CardDocLinks">
        export default {
          mounted() {
            this.onClick = (event) => {
              const link = event.target.closest("a[href^='/documents/']:not([data-viewer])")
              const modified = event.metaKey || event.ctrlKey || event.shiftKey || event.altKey
              if (!link || event.defaultPrevented || event.button !== 0 || modified) return
              event.preventDefault()
              event.stopPropagation()
              this.pushEvent("open-doc", {href: link.getAttribute("href")})
            }
            this.el.addEventListener("click", this.onClick)
          },
          destroyed() {
            this.el.removeEventListener("click", this.onClick)
          }
        }
      </script>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :item, :map, required: true
  attr :prefix, :string, default: ""
  attr :event, :string, default: "resolve"
  attr :repos, :list, default: nil

  @doc "One pending card from a stream item (`ForemanWeb.CardItems.item/4`)."
  def request_card(assigns) do
    ~H"""
    <ForemanWeb.OpenCard.card
      id={@id}
      request={@item.request}
      prefix={@prefix}
      event={@event}
      card={@item.card}
      question={@item.question}
      focus={@item.focus}
      footer={@item.footer}
      heading={@item.heading}
      repos={@repos}
    />
    """
  end
end
