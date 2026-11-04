defmodule ForemanWeb.NeedsYouLive do
  @moduledoc """
  Needs you: the triage list of pending cards (question cards spec, Decisions
  1-11, 29-32). Every pending card is one row and at most one is open; which one
  is open, and the lines that say what happened to a card, sit on
  `Foreman.CardList`. The open card is in the URL as `?card=<id>`. Each card's
  input and notices are kept by card id (`ForemanWeb.CardItems`), so closing,
  switching or a poll never loses them.
  """
  use ForemanWeb, :live_view
  alias Foreman.{CardList, Requests}
  alias Fluxon.Components.{Button, Badge}
  alias ForemanWeb.{CardFooter, CardItems, CardLines}

  @cards [
    stream: :pending,
    ui: :card_ui,
    footers: :card_footers,
    prefix: ""
  ]

  # How long a result line stays (Decision 30, R8).
  @line_ms 10_000

  def mount(params, _, socket) do
    socket =
      socket
      |> assign(list: CardList.new(), cards: %{}, shown: [], card_url: nil)
      |> CardItems.assigns(@cards)
      |> assign(panel: Foreman.CardPanel.__fsm__(:initial), panel_doc: nil, card_repos: [])
      |> stream_configure(:pending, dom_id: & &1.dom)
      |> stream(:pending, [])

    # The list loads once the page is connected; until then it shows the loading state.
    if connected?(socket) do
      Process.send_after(self(), :reconcile, 3_000)
      {:ok, load(socket, want: params["card"])}
    else
      {:ok, socket |> stream(:recent, []) |> merge_list()}
    end
  end

  def handle_params(params, uri, socket) do
    socket = socket |> ForemanWeb.TicketDetail.load(params, uri) |> panel(params)
    card = params["card"]

    socket =
      if socket.assigns.list.state != :loading and card != nil and
           card != socket.assigns.list.open,
         do: change(socket, &CardList.open_row(&1, card)),
         else: socket

    {:noreply, socket |> assign(:card_url, card) |> patch_url()}
  end

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
    action = action(params)

    if action in CardLines.resolving(),
      do: {:noreply, act(socket, params, action)},
      else: {:noreply, other_action(socket, params)}
  end

  def handle_event("resolve-text", params, socket),
    do: {:noreply, CardItems.text(socket, @cards, params)}

  # A row click, Enter or Space: the URL names the card, and handle_params opens it.
  def handle_event("open-card", %{"id" => id}, socket),
    do: {:noreply, push_patch(socket, to: card_path(socket, id))}

  def handle_event("close-card", _, socket) do
    socket = change(socket, &CardList.close/1)
    {:noreply, push_patch(socket, to: card_path(socket, nil))}
  end

  def handle_event("dismiss-line", %{"id" => id}, socket),
    do: {:noreply, change(socket, &CardList.dismiss_line(&1, id))}

  def handle_event("reload-cards", _, socket), do: {:noreply, socket |> load() |> patch_url()}

  # Try again on an error line: the same action, with the input kept now.
  def handle_event("retry-card", %{"id" => id}, socket) do
    case socket.assigns.list.error do
      %{id: ^id, action: action, params: params} ->
        footer = CardFooter.get(socket.assigns.card_footers, id)
        {:noreply, act(socket, with_input(params, footer), action)}

      _ ->
        {:noreply, socket}
    end
  end

  # Document links on cards and in the panel open in the side panel; the hook
  # leaves modified clicks (new tab) to the browser, which opens the viewer.
  def handle_event("open-doc", %{"href" => href}, socket) do
    case Foreman.CardPanel.doc_param(href) do
      nil -> {:noreply, socket}
      doc -> {:noreply, push_patch(socket, to: page_path(socket, %{"doc" => doc}))}
    end
  end

  def handle_event("close-panel", _, socket) do
    if socket.assigns.panel == :closed,
      do: {:noreply, socket},
      else: {:noreply, push_patch(socket, to: page_path(socket, %{}))}
  end

  def handle_event("close-ticket", params, socket),
    do: {:noreply, ForemanWeb.TicketDetail.close(socket, params)}

  def handle_event("ticket-priority", params, socket),
    do:
      {:noreply,
       socket
       |> ForemanWeb.TicketDetail.priority(params)
       |> load()
       |> patch_url()
       |> ForemanWeb.TicketDetail.refresh()}

  def handle_event("ticket-jump", params, socket),
    do:
      {:noreply,
       socket
       |> ForemanWeb.TicketDetail.jump(params)
       |> load()
       |> patch_url()
       |> ForemanWeb.TicketDetail.refresh()}

  @doc "Resolves a shared request form, regardless of its page or drawer location."
  def resolve(%{"id" => id, "action" => "ask"} = params),
    do: ask(id, CardFooter.text(params) || "")

  def resolve(%{"id" => id, "action" => "wrong-question"} = params),
    do: Requests.resolve(id, :wrong_question, %{"note" => CardFooter.text(params)})

  def resolve(%{"id" => id, "action" => "withdraw"} = params),
    do: Requests.withdraw_from_card(id, CardFooter.text(params))

  def resolve(%{"id" => id, "action" => "batch-answer", "batch" => batch}), do: batch(id, batch)

  # Enter in the batch form submits it with no button: the answer.
  def resolve(%{"id" => id, "batch" => batch} = params) when not is_map_key(params, "action"),
    do: batch(id, batch)

  def resolve(%{"id" => id, "decision" => params, "action" => "answer"}) do
    answer = if params["choice"] in [nil, ""], do: params["note"], else: params["choice"]

    Requests.resolve(id, :answer, %{
      "answer" => answer,
      "note" => params["note"],
      "image_comments" => params["image_comments"]
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

  def resolve(%{"id" => id, "action" => "complete"} = params),
    do: Requests.resolve(id, :complete, note(get_in(params, ["chore", "note"])))

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

  defp batch(id, batch),
    do:
      Requests.resolve(id, :answer, Map.put(note(batch["note"]), "answer", batch["items"] || []))

  defp note(text) when is_binary(text) and text != "", do: %{"note" => text}
  defp note(_), do: %{}

  # Ask (Decision 18): a live source gets the question; otherwise the card shows
  # the copy field, and a failed send shows why.
  defp ask(id, text) do
    with false <- String.trim(text) == "",
         %{state: "pending"} = request <- Requests.get(id),
         %{state: :live} <- Foreman.RequestSource.view(request) do
      case Foreman.CardMessages.ask(id, text) do
        {:ok, message} -> {:ok, message}
        {:error, "refused in preview"} -> ask_failed(id, {:error, :tmux_unavailable}, text)
        {:error, :source_unknown} -> {:card, id, {:ask, :unsendable, nil, text}}
        error -> ask_failed(id, error, text)
      end
    else
      true -> {:error, :text_required}
      %{state: source} when is_atom(source) -> {:card, id, {:ask, :unsendable, nil, text}}
      _ -> {:error, :not_found}
    end
  end

  defp ask_failed(id, result, text) do
    case card(id, result) do
      {:card, ^id, reason} -> {:card, id, {:ask, :failed, reason, text}}
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
    {:noreply, poll(socket)}
  end

  def handle_info({:notification, :foreman_events, _}, socket), do: {:noreply, poll(socket)}

  def handle_info({:line_expired, id}, socket),
    do: {:noreply, change(socket, &CardList.line_expired(&1, id))}

  defp poll(socket) do
    socket = socket |> load() |> patch_url()

    if socket.assigns.list.load_error,
      do: socket,
      else: socket |> ForemanWeb.TicketDetail.refresh() |> refresh_panel()
  end

  defp action(%{"action" => action}), do: action
  defp action(%{"batch" => _}), do: "batch-answer"
  defp action(_), do: nil

  # An action that takes the card out of pending (Decision 39: `resolved` or
  # `resolve_failed` when it fails).
  defp act(socket, %{"id" => id} = params, action) do
    socket = CardItems.text(socket, @cards, Map.put(params, "card_id", id))
    before = with {:error, :database} <- safely(fn -> Requests.get(id) end), do: nil

    case safely(fn -> resolve(params) end) do
      {:navigate, path} ->
        push_navigate(socket, to: path)

      {:card, ^id, notice} ->
        socket |> CardItems.keep_notice(@cards, id, notice) |> load() |> patch_url()

      {:ok, _} ->
        request = safely(fn -> Requests.get(id) end)

        if match?(%{state: state} when state not in ["pending", "superseded"], request) and
             id == socket.assigns.list.open do
          view = Foreman.RequestSource.view(before || request)
          line = CardLines.result_info(action, request, params, view)
          socket |> load(resolved: {id, line}) |> patch_url()
        else
          socket |> load() |> patch_url()
        end

      {:error, reason} ->
        if pending?(id) and id == socket.assigns.list.open do
          kind = before && before.kind
          error = CardLines.error_info(id, action, reason, kind, params)
          socket |> change(&CardList.resolve_failed(&1, id, error))
        else
          socket |> load() |> patch_url()
        end
    end
  end

  defp act(socket, _, _), do: socket

  # A card action that keeps the card pending: Ask, Focus terminal, Open session, Continue.
  defp other_action(socket, params) do
    outcome = resolve(params)
    socket = CardItems.keep_sent(socket, @cards, params, outcome)

    case outcome do
      {:navigate, path} ->
        push_navigate(socket, to: path)

      {:card, id, notice} ->
        socket |> CardItems.keep_notice(@cards, id, notice) |> load() |> patch_url()

      {:ok, _} ->
        socket |> load() |> patch_url()

      {:error, _} ->
        socket |> put_flash(:error, "Request not updated") |> load() |> patch_url()
    end
  end

  # A database that does not answer is a reason on the error line, not a crash.
  defp safely(fun) do
    fun.()
  rescue
    e ->
      if Foreman.Repo.unavailable?(e), do: {:error, :database}, else: reraise(e, __STACKTRACE__)
  end

  defp pending?(id) do
    match?(%{state: "pending"}, Requests.get(id))
  rescue
    e -> if Foreman.Repo.unavailable?(e), do: true, else: reraise(e, __STACKTRACE__)
  end

  # Try again sends the kept text and choice, not the ones of the failed submit.
  defp with_input(params, footer) do
    params =
      Enum.reduce(~w(decision batch chore waiting), params, fn form, params ->
        case params do
          %{^form => %{} = fields} -> Map.put(params, form, Map.put(fields, "note", footer.text))
          _ -> params
        end
      end)

    case {params, footer.choice} do
      {%{"decision" => decision}, choice} when is_binary(choice) ->
        Map.put(params, "decision", Map.put(decision, "choice", choice))

      {%{"batch" => batch}, items} when is_list(items) ->
        Map.put(params, "batch", Map.put(batch, "items", items))

      _ ->
        params
    end
  end

  # Reads the pending cards and fires `loaded` (or `resolved`, after your action)
  # on the list. When the database does not answer, the list keeps its rows.
  defp load(socket, opts \\ []) do
    case read_pending() do
      {:ok, pending, versions} ->
        ids = Enum.map(pending, & &1.id)
        footers = socket.assigns.card_footers

        closed = fn id ->
          CardLines.closed_info(id, Requests.get(id), CardFooter.get(footers, id).text)
        end

        socket =
          assign(socket,
            cards: Map.new(pending, &{&1.id, {&1, versions[&1.id]}}),
            card_repos: Foreman.CardText.repos()
          )

        socket =
          case opts[:resolved] do
            {id, line} -> change(socket, &CardList.resolved(&1, id, ids, line))
            nil -> change(socket, &CardList.loaded(&1, ids, want: opts[:want], closed: closed))
          end

        socket
        |> CardItems.prune(@cards, MapSet.new(ids))
        |> sync()
        |> ForemanWeb.RequestCount.refresh()
        |> stream(:recent, Requests.recent(), reset: true)
        |> merge_list()

      :error ->
        change(socket, &CardList.load_failed/1)
    end
  end

  defp read_pending do
    pending = Requests.pending()
    messages = Foreman.CardMessages.versions(Enum.map(pending, & &1.id))
    versions = Map.new(pending, &{&1.id, {messages[&1.id], &1.edited_at, &1.similar_question}})
    {:ok, pending, versions}
  rescue
    e -> if Foreman.Repo.unavailable?(e), do: :error, else: reraise(e, __STACKTRACE__)
  end

  # Fires one list event and does its host effects.
  defp change(socket, fun) do
    {list, effects} = fun.(socket.assigns.list)

    effects
    |> Enum.reduce(assign(socket, :list, list), fn
      {:card_closed, id}, socket ->
        update(socket, :card_footers, &CardFooter.step(&1, id, :card_closed))

      {:drop_input, id}, socket ->
        socket
        |> update(:card_footers, &CardFooter.drop(&1, id))
        |> update(:card_ui, &Map.delete(&1, id))

      {:expire, id}, socket ->
        timer = Application.get_env(:foreman, :card_line_timer, &Process.send_after/3)
        timer.(self(), {:line_expired, id}, @line_ms)
        socket
    end)
    |> sync()
  end

  # Draws the list from the machine: the rows, the open card and the lines, in
  # list order. A changed order redraws the list; otherwise only changed items
  # are sent, so a poll leaves the open card's form alone.
  defp sync(socket) do
    list = socket.assigns.list

    items =
      Enum.flat_map(list.order, fn id ->
        case {list.lines[id], socket.assigns.cards[id]} do
          {{kind, line}, _} -> [%{dom: "card-line-" <> id, id: id, kind: kind, line: line}]
          {nil, nil} -> []
          {nil, card} -> [card_item(socket, card, list)]
        end
      end)

    shown = Enum.map(items, &{&1.dom, Map.delete(&1, :request)})
    previous = socket.assigns.shown

    socket =
      if Enum.map(shown, &elem(&1, 0)) == Enum.map(previous, &elem(&1, 0)) do
        previous = Map.new(previous)

        items
        |> Enum.zip(shown)
        |> Enum.reduce(socket, fn {item, {dom, key}}, socket ->
          if previous[dom] == key, do: socket, else: stream_insert(socket, :pending, item)
        end)
      else
        stream(socket, :pending, items, reset: true)
      end

    assign(socket, :shown, shown)
  end

  defp card_item(socket, {request, version}, list) do
    open? = request.id == list.open

    item =
      if open?,
        do: CardItems.item(socket, @cards, request, false),
        else: %{id: request.id, request: request}

    Map.merge(item, %{
      dom: "request-" <> request.id,
      kind: if(open?, do: :open, else: :row),
      version: version,
      error: if(open? and match?(%{id: id} when id == request.id, list.error), do: list.error)
    })
  end

  # The URL names the open card (Decision 7). A card the board opened by itself
  # replaces the URL; Close card and row clicks patch it themselves.
  defp patch_url(socket) do
    open = socket.assigns.list.open

    if connected?(socket) and socket.assigns.list.state != :loading and
         Map.has_key?(socket.assigns, :page_uri) and open != socket.assigns.card_url,
       do: push_patch(socket, to: card_path(socket, open), replace: true),
       else: socket
  end

  defp card_path(socket, id) do
    params = current_params(socket)
    params = if id, do: Map.put(params, "card", id), else: Map.delete(params, "card")
    path(params)
  end

  # The ticket and document panel parameters stay next to `card`.
  defp page_path(socket, panel) do
    current_params(socket)
    |> Map.take(["card"])
    |> Map.merge(panel)
    |> path()
  end

  defp current_params(socket) do
    case socket.assigns[:page_uri] do
      nil -> %{}
      uri -> URI.decode_query(URI.parse(uri).query || "")
    end
  end

  defp path(params) when params == %{}, do: "/needs-you"
  defp path(params), do: "/needs-you?" <> URI.encode_query(params)

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
          <div :if={@list.notice || @list.load_error} id="cards-notices" class="max-w-3xl space-y-2">
            <ForemanWeb.StatusLine.status_line
              :if={@list.load_error}
              id="cards-error"
              kind={:error}
              retry={JS.push("reload-cards")}
              retry_id="cards-retry"
            >
              <b class="font-semibold">Could not load cards.</b>
              The database did not answer. The list shows the last cards it loaded.
            </ForemanWeb.StatusLine.status_line>
            <ForemanWeb.StatusLine.status_line
              :if={@list.notice == :stale}
              id="cards-notice"
              kind={:info}
            >
              That card is no longer open. Find it in Recent outcomes.
            </ForemanWeb.StatusLine.status_line>
          </div>
          <div
            :if={@list.state == :loading}
            id="cards-loading"
            role="status"
            class="bb-tri bb-tri-loading max-w-3xl"
          >
            <span class="sr-only">Loading cards…</span>
            <div class="bb-skel-card" aria-hidden="true">
              <span class="bb-skel w-2/5"></span>
              <span class="bb-skel w-3/4"></span>
              <span class="bb-skel w-full"></span>
              <span class="bb-skel w-full"></span>
            </div>
            <div :for={_ <- 1..2} class="bb-skel-row" aria-hidden="true">
              <span class="bb-skel w-16"></span><span class="bb-skel flex-1"></span>
            </div>
          </div>
          <div id="pending-requests" phx-update="stream" class="bb-tri max-w-3xl">
            <div :for={{id, item} <- @streams.pending} id={id} class={"bb-tri-item-#{item.kind}"}>
              <%= case item.kind do %>
                <% :open -> %>
                  <.request_card id={"article-" <> item.id} item={item} repos={@card_repos} />
                <% :row -> %>
                  <ForemanWeb.CardRow.row request={item.request} />
                <% :result -> %>
                  <CardLines.result_line line={item.line} />
                <% :closed -> %>
                  <CardLines.closed_line line={item.line} />
              <% end %>
            </div>
          </div>
          <div
            :if={@list.state == :empty}
            id="inbox-empty"
            class="max-w-3xl rounded-xl border border-dashed border-base p-10 text-center text-sm text-foreground-softer"
          >
            <b class="font-semibold text-foreground">Nothing waits on you.</b>
            New questions and approvals from sessions show here.
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
      focus={@item.focus}
      footer={@item.footer}
      heading={@item.heading}
      repos={@repos}
      close={if(@prefix == "", do: "close-card")}
      error={Map.get(@item, :error)}
    />
    """
  end
end
