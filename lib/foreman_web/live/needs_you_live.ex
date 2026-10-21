defmodule ForemanWeb.NeedsYouLive do
  use ForemanWeb, :live_view
  alias Foreman.Requests
  alias Fluxon.Components.{Button, Badge}

  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :reconcile, 3_000)

    {:ok,
     socket
     |> assign(:pending_ids, MapSet.new())
     |> assign(:pending_headings, MapSet.new())
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

  def handle_event("resolve", params, socket), do: {:noreply, result(socket, resolve(params))}

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
  def resolve(%{"id" => id, "decision" => params, "action" => "answer"}) do
    answer = if params["choice"] in [nil, ""], do: params["note"], else: params["choice"]
    Requests.resolve(id, :answer, %{"answer" => answer, "note" => params["note"]})
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

  @doc "A pending-stream entry: the request and its card notice."
  def item(request, card \\ Foreman.WaitingCard.__fsm__(:initial), heading \\ false)

  def item(request, {:focus, state}, heading),
    do: %{id: request.id, request: request, card: :ready, focus: state, heading: heading}

  def item(request, card, heading),
    do: %{id: request.id, request: request, card: card, focus: :ready, heading: heading}

  def grouped(pending) do
    keys = pending |> Enum.map(&{&1.repo_key, &1.bead_id}) |> Enum.uniq()
    groups = Enum.group_by(pending, &{&1.repo_key, &1.bead_id})

    Enum.flat_map(keys, fn key ->
      groups[key]
      |> Enum.with_index()
      |> Enum.map(fn {request, index} -> item(request, :ready, index == 0) end)
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
    case Requests.get(id) do
      %{state: "pending"} = request ->
        [request] = Requests.with_priority([request])

        stream_insert(
          socket,
          :pending,
          item(request, card, MapSet.member?(socket.assigns.pending_headings, id))
        )

      _ ->
        refresh(socket)
    end
  end

  defp result(socket, {:ok, _}), do: refresh(socket)

  defp result(socket, {:error, _}),
    do: socket |> put_flash(:error, "Request not updated") |> refresh()

  defp refresh(socket) do
    pending = Requests.pending()
    ids = MapSet.new(pending, & &1.id)
    socket = assign(socket, :card_repos, Foreman.CardText.repos())
    previous = socket.assigns.pending_ids
    items = grouped(pending)
    headings = items |> Enum.filter(& &1.heading) |> MapSet.new(& &1.id)

    # Pending facts are immutable. Leave existing cards mounted so reconciliation
    # cannot erase an answer or note the user is still composing.
    socket =
      Enum.reduce(MapSet.difference(previous, ids), socket, fn id, socket ->
        stream_delete_by_dom_id(socket, :pending, "request-" <> id)
      end)

    socket =
      items
      |> Enum.with_index()
      |> Enum.reduce(socket, fn {item, index}, socket ->
        if MapSet.member?(previous, item.id) and
             MapSet.member?(socket.assigns.pending_headings, item.id) == item.heading,
           do: socket,
           else: stream_insert(socket, :pending, item, at: index)
      end)

    socket
    |> assign(:pending_ids, ids)
    |> assign(:pending_headings, headings)
    |> ForemanWeb.RequestCount.refresh()
    |> stream(:recent, Requests.recent(), reset: true)
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
              request={item.request}
              card={item.card}
              focus={item.focus}
              heading={item.heading}
              repos={@card_repos}
            />
          </div>
          <details id="recent-outcomes" class="max-w-3xl border-t border-base pt-4">
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
        <aside
          :if={@panel != :closed}
          id="card-panel"
          aria-label={if(@panel == :ticket, do: "Ticket", else: "Document")}
          phx-window-keydown="close-panel"
          phx-key="Escape"
          class="fixed inset-0 z-40 space-y-6 overflow-y-auto bg-base p-5 lg:sticky lg:inset-auto lg:top-6 lg:z-auto lg:max-h-[calc(100vh-3rem)] lg:rounded-xl lg:border lg:border-base lg:p-6 lg:shadow-sm"
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
              <span class="min-w-0 flex-1 break-all font-mono" title={@panel_doc.path}>
                {@panel_doc.path}
              </span>
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
  attr :request, :any, required: true

  attr :prefix, :string, default: ""
  attr :event, :string, default: "resolve"
  attr :card, :atom, default: :ready
  attr :focus, :atom, default: :ready
  attr :repos, :list, default: nil

  attr :heading, :boolean, default: false

  def request_card(assigns) do
    assigns =
      assign(
        assigns,
        :title,
        if(assigns.heading, do: Foreman.RequestHeader.for_request(assigns.request).title)
      )

    ~H"""
    <article id={@id}>
      <h2 :if={@heading} data-ticket-heading="true" class="mb-3 text-base font-semibold">{@title}</h2>
      <.card_body
        id={"card-" <> @id}
        request={@request}
        prefix={@prefix}
        event={@event}
        card={@card}
        focus={@focus}
        heading={@heading}
        repos={@repos}
      />
    </article>
    """
  end

  defp card_body(%{request: %{kind: kind}} = assigns) when kind in ["push", "open_pr", "merge"],
    do: action_card(assigns)

  defp card_body(%{request: %{kind: "session_waiting"}} = assigns), do: waiting_card(assigns)
  defp card_body(assigns), do: decision_card(assigns)

  def waiting_card(assigns) do
    question =
      if Foreman.Request.inline_question?(Requests.context(assigns.request), nil),
        do: hd(assigns.request.facts["questions"])

    assigns =
      assign(assigns,
        form: to_form(%{}, as: :waiting),
        other: to_form(%{"other" => ""}, as: :reply),
        reply: to_form(%{"text" => ""}, as: :reply),
        question: question
      )

    ~H"""
    <article id={@id} class="rounded-xl border border-base bg-base p-5 shadow-sm sm:p-6">
      <ForemanWeb.RequestContext.context
        request={@request}
        prefix={@prefix}
        event={@event}
        focus={@focus}
        heading={@heading}
      />
      <div class="mb-4 flex flex-wrap items-center gap-2 text-xs text-foreground-softer">
        <Badge.badge>Session waiting</Badge.badge>
        <ForemanWeb.RequestCard.ticket_link
          id={@prefix <> "ticket-link-" <> @request.id}
          request={@request}
          link={if(@prefix == "", do: :patch, else: :navigate)}
        />
        <span class="ml-auto"><ForemanWeb.TicketDetail.timestamp at={@request.inserted_at} /></span>
      </div>
      <ForemanWeb.RequestCard.waiting_facts request={@request} />
      <%= if @question do %>
        <ForemanWeb.RequestCard.agent_text
          id={@prefix <> "question-" <> @request.id}
          text={@question["question"]}
          repo={@request.repo_key}
          repos={@repos}
          class="fm-card-question mt-4"
        />
        <.form
          for={@form}
          id={@prefix <> "answer-" <> @request.id}
          phx-submit={@event}
          phx-value-id={@request.id}
          phx-value-action="reply"
          class="mt-3 grid gap-2 sm:grid-cols-2"
        >
          <Button.button
            :for={{label, index} <- Enum.with_index(@question["options"])}
            id={@prefix <> "answer-" <> @request.id <> "-" <> Integer.to_string(index)}
            type="submit"
            name="reply[choice]"
            value={index}
            phx-disable-with="Sending…"
            class="h-auto min-h-10 justify-start whitespace-normal py-2 text-left [overflow-wrap:anywhere]"
          >
            {label}
          </Button.button>
        </.form>
        <.form
          for={@other}
          id={@prefix <> "other-" <> @request.id}
          phx-submit={@event}
          phx-value-id={@request.id}
          phx-value-action="reply"
          class="mt-2 flex gap-2"
        >
          <input
            id={@prefix <> "other-text-" <> @request.id}
            type="text"
            name="reply[other]"
            required
            maxlength="2000"
            placeholder="Other"
            aria-label="Other answer"
            class="min-w-0 flex-1 rounded-lg border border-base bg-sunken px-3 py-2 text-sm text-foreground outline-none transition focus:border-primary focus:ring-2 focus:ring-primary/20"
          />
          <Button.button
            id={@prefix <> "other-send-" <> @request.id}
            type="submit"
            name="reply[choice]"
            value="other"
            phx-disable-with="Sending…"
          >
            Send
          </Button.button>
        </.form>
      <% end %>
      <%= if @request.facts["reason"] == "question" do %>
        <ForemanWeb.RequestCard.agent_text
          id={@prefix <> "chat-question-" <> @request.id}
          text={@request.facts["question"]}
          repo={@request.repo_key}
          repos={@repos}
          class="mt-4"
        />
        <.form
          for={@reply}
          id={@prefix <> "reply-" <> @request.id}
          phx-submit={@event}
          phx-value-id={@request.id}
          phx-value-action="reply"
          class="mt-3 flex gap-2"
        >
          <input
            id={@prefix <> "reply-text-" <> @request.id}
            type="text"
            name="reply[text]"
            required
            maxlength="2000"
            autocomplete="off"
            aria-label="Reply"
            class="min-w-0 flex-1 rounded-lg border border-base bg-sunken px-3 py-2 text-sm text-foreground outline-none transition focus:border-primary focus:ring-2 focus:ring-primary/20"
          />
          <Button.button
            id={@prefix <> "reply-send-" <> @request.id}
            type="submit"
            variant="solid"
            phx-disable-with="Sending…"
          >
            Reply
          </Button.button>
        </.form>
      <% end %>
      <%= if is_nil(@question) do %>
        <ul
          :if={is_list(@request.facts["questions"])}
          id={@prefix <> "questions-" <> @request.id}
          class="mt-4 space-y-3"
        >
          <li
            :for={{question, index} <- Enum.with_index(@request.facts["questions"])}
            class="space-y-1"
          >
            <ForemanWeb.RequestCard.agent_text
              id={@prefix <> "questions-" <> @request.id <> "-" <> Integer.to_string(index)}
              text={question["question"]}
              repo={@request.repo_key}
              repos={@repos}
              class="font-medium"
            />
            <p class="break-words text-sm text-foreground-softer">
              {Enum.join(question["options"], " · ")}
            </p>
          </li>
        </ul>
      <% end %>
      <div class="mt-4 flex flex-wrap items-center gap-2">
        <Button.button
          id={@prefix <> "open-" <> @request.id}
          type="button"
          phx-click={@event}
          phx-value-id={@request.id}
          phx-value-action="open"
          phx-disable-with="Opening…"
          variant={
            if(@question || @request.facts["reason"] == "question", do: "outline", else: "solid")
          }
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Open session
        </Button.button>
        <.form
          :if={@request.facts["reason"] == "usage_limit"}
          for={@form}
          id={@prefix <> "waiting-" <> @request.id}
          phx-submit={@event}
          phx-value-id={@request.id}
        >
          <Button.button
            id={@prefix <> "continue-" <> @request.id}
            type="submit"
            name="action"
            value="continue"
            phx-disable-with="Continuing…"
          >
            Continue
          </Button.button>
        </.form>
      </div>
      <div
        :if={@card != :ready}
        id={@prefix <> "notice-" <> @request.id}
        role="status"
        class="mt-3 space-y-2 text-sm text-foreground-softer"
      >
        <p>
          {%{
            unattached: "No terminal is attached to this session's tmux server. Attach with:",
            window_gone: "Session window is gone.",
            prompt_changed: "The question is no longer on screen. Open the session to answer it.",
            prompt_busy: "The session is not at its prompt. Open the session to reply.",
            tmux_unavailable: "tmux is unavailable."
          }[@card]}
        </p>
        <code
          :if={@card == :unattached and @request.facts["attach"]}
          id={@prefix <> "attach-" <> @request.id}
          class="block select-all break-all rounded-md bg-sunken px-2 py-1 font-mono text-xs"
        >
          {@request.facts["attach"]}
        </code>
      </div>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :request, :any, required: true

  def action_card(assigns) do
    assigns = assign(assigns, :form, to_form(%{"note" => ""}, as: :decision))

    ~H"""
    <article id={@id} class="rounded-xl border border-base bg-base p-5 shadow-sm sm:p-6">
      <ForemanWeb.RequestContext.context
        request={@request}
        prefix={@prefix}
        event={@event}
        focus={@focus}
        heading={@heading}
      />
      <div class="mb-4 flex flex-wrap items-center gap-2 text-xs text-foreground-softer">
        <Badge.badge>
          {%{"push" => "Push", "open_pr" => "Open PR", "merge" => "Merge"}[@request.kind]}
        </Badge.badge>
        <ForemanWeb.RequestCard.ticket_link
          id={@prefix <> "ticket-link-" <> @request.id}
          request={@request}
          link={if(@prefix == "", do: :patch, else: :navigate)}
        />
        <span>{@request.actor}<span :if={@request.session}> · {@request.session}</span></span>
        <span class="ml-auto"><ForemanWeb.TicketDetail.timestamp at={@request.inserted_at} /></span>
      </div>
      <ForemanWeb.RequestCard.push_facts :if={@request.kind == "push"} request={@request} />
      <ForemanWeb.RequestCard.open_pr_facts
        :if={@request.kind == "open_pr"}
        request={@request}
        repos={@repos}
        prefix={@prefix}
      />
      <ForemanWeb.RequestCard.merge_facts :if={@request.kind == "merge"} request={@request} />
      <.form
        for={@form}
        id={@prefix <> @request.kind <> "-" <> @request.id}
        phx-submit={@event}
        phx-value-id={@request.id}
        class="mt-5 space-y-4"
      >
        <.input
          field={@form[:note]}
          id={@prefix <> @request.kind <> "-note-" <> @request.id}
          type="textarea"
          label="Note"
          rows="2"
          class="mt-2 block w-full rounded-lg border border-base bg-sunken px-3 py-2 text-foreground outline-none transition focus:border-primary focus:ring-2 focus:ring-primary/20"
        />
        <div class="flex gap-2">
          <Button.button
            id={@prefix <> "submit-approve-" <> @request.id}
            type="submit"
            name="action"
            value="approve"
            variant="solid"
            color="primary"
          >
            Approve
          </Button.button>
          <Button.button
            id={@prefix <> "submit-decline-" <> @request.id}
            type="submit"
            name="action"
            value="decline"
          >
            Decline
          </Button.button>
        </div>
      </.form>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :request, :any, required: true

  def decision_card(assigns) do
    assigns =
      assign(
        assigns,
        :form,
        to_form(%{"note" => "", "choice" => ""}, as: :decision)
      )

    ~H"""
    <article id={@id} class="rounded-xl border border-base bg-base p-5 shadow-sm sm:p-6">
      <ForemanWeb.RequestContext.context
        request={@request}
        prefix={@prefix}
        event={@event}
        focus={@focus}
        heading={@heading}
      />
      <div class="mb-4 flex flex-wrap items-center gap-2 text-xs text-foreground-softer">
        <Badge.badge>Decision</Badge.badge>
        <ForemanWeb.RequestCard.ticket_link
          id={@prefix <> "ticket-link-" <> @request.id}
          request={@request}
          link={if(@prefix == "", do: :patch, else: :navigate)}
        />
        <span>{@request.actor}<span :if={@request.session}> · {@request.session}</span></span>
        <span class="ml-auto"><ForemanWeb.TicketDetail.timestamp at={@request.inserted_at} /></span>
      </div>
      <ForemanWeb.RequestCard.agent_text
        id={@prefix <> "question-" <> @request.id}
        text={@request.facts["question"]}
        repo={@request.repo_key}
        repos={@repos}
        class="fm-card-question"
      />
      <ForemanWeb.RequestCard.agent_text
        :if={@request.facts["text"]}
        id={@prefix <> "text-" <> @request.id}
        text={@request.facts["text"]}
        repo={@request.repo_key}
        repos={@repos}
        class="mt-2 text-foreground-softer"
      />
      <ForemanWeb.RequestCard.doc_links
        id={@prefix <> "docs-" <> @request.id}
        request={@request}
      />
      <.form
        for={@form}
        id={@prefix <> "decision-" <> @request.id}
        phx-submit={@event}
        phx-value-id={@request.id}
        class="mt-5 space-y-4"
      >
        <fieldset :if={@request.facts["options"] != []} class="space-y-2">
          <legend class="sr-only">Options</legend>
          <label
            :for={{option, index} <- Enum.with_index(@request.facts["options"])}
            data-recommended={to_string(option == @request.facts["recommendation"])}
            class="flex cursor-pointer items-center gap-3 rounded-lg border border-base px-3 py-3 hover:bg-sunken has-[:checked]:border-primary has-[:checked]:bg-sunken"
          >
            <input
              id={"#{@prefix}option-#{@request.id}-#{index}"}
              type="radio"
              name="decision[choice]"
              value={option}
              class="size-4 shrink-0 accent-current"
            />
            <span class="min-w-0 flex-1 break-words">
              <span class="block">{option}</span>
              <span
                :if={get_in(@request.facts, ["option_details", option])}
                id={"#{@prefix}option-detail-#{@request.id}-#{index}"}
                class="mt-1 block text-sm text-foreground-softer"
              >
                {get_in(@request.facts, ["option_details", option])}
              </span>
            </span>
            <span
              :if={option == @request.facts["recommendation"]}
              class="text-xs text-foreground-softer"
            >
              Recommended
            </span>
          </label>
        </fieldset>
        <.input
          field={@form[:note]}
          id={@prefix <> "decision-note-" <> @request.id}
          type="textarea"
          label="Note"
          rows="2"
          class="mt-2 block w-full rounded-lg border border-base bg-sunken px-3 py-2 text-foreground outline-none transition focus:border-primary focus:ring-2 focus:ring-primary/20"
        />
        <div id={@prefix <> "decision-actions-" <> @request.id} class="flex gap-3">
          <Button.button
            type="submit"
            name="action"
            value="answer"
            id={@prefix <> "submit-answer-" <> @request.id}
            variant="solid"
          >
            Answer
          </Button.button>
          <Button.button
            type="submit"
            name="action"
            value="decline"
            id={@prefix <> "submit-decline-" <> @request.id}
          >
            Decline
          </Button.button>
        </div>
      </.form>
    </article>
    """
  end
end
