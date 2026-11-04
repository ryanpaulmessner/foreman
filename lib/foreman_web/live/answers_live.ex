defmodule ForemanWeb.AnswersLive do
  use ForemanWeb, :live_view
  alias Foreman.{Answers, CardText, Markdown}
  alias ForemanWeb.{RequestCard, StatusLine, TicketDetail}
  alias Fluxon.Components.Button

  @impl true
  def mount(_, _, socket) do
    {:ok,
     socket
     |> assign(
       tab: Answers.Tab.__fsm__(:initial),
       load: Answers.Load.__fsm__(:initial),
       notice: Answers.Notice.__fsm__(:initial),
       archived: nil,
       viewer: Answers.Expansion.__fsm__(:initial),
       selected: nil,
       limit: 50,
       counts: %{saved: 0, yours: 0, rules: 0},
       empty?: false,
       more?: false,
       repos: CardText.repos() |> Enum.map(&{&1["key"], &1["key"]}),
       filters: %{},
       form: to_form(%{}, as: :filters)
     )
     |> stream(:answers, [], dom_id: &"answer-#{&1.id}")
     |> stream(:standing, [], dom_id: &"always-rule-#{&1.id}")
     |> stream(:yours, [], dom_id: &"your-answer-#{&1.id}")}
  end

  @impl true
  def handle_params(params, _, socket) do
    selected = params["id"]
    {tab, []} = Answers.Tab.step(socket.assigns.tab, :select, %{tab: params["tab"]})

    {viewer, []} =
      Answers.Expansion.step(
        socket.assigns.viewer,
        if(selected, do: :expand, else: :collapse),
        %{}
      )

    socket = assign(socket, selected: selected, viewer: viewer, tab: tab, limit: 50)
    {:noreply, if(connected?(socket), do: refresh(socket, true), else: socket)}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    filters = Map.take(filters, ["search", "repo", "ticket", "archived"])

    {:noreply,
     socket
     |> assign(filters: filters, form: to_form(filters, as: :filters), limit: 50)
     |> refresh()}
  end

  def handle_event("clear-filters", _, socket) do
    {:noreply,
     socket |> assign(filters: %{}, form: to_form(%{}, as: :filters), limit: 50) |> refresh()}
  end

  def handle_event("retry", _, socket), do: {:noreply, refresh(socket, true)}

  def handle_event("more", _, socket) do
    {:noreply, socket |> update(:limit, &(&1 + 50)) |> refresh()}
  end

  def handle_event("state", %{"id" => id, "event" => event}, socket)
      when event in ["pin", "unpin", "archive", "restore"] do
    event =
      %{"pin" => :pin, "unpin" => :unpin, "archive" => :archive, "restore" => :restore}[event]

    {:noreply, change_answer(socket, id, event)}
  end

  def handle_event("undo", _, %{assigns: %{notice: :archived, archived: answer}} = socket) do
    {:noreply, change_answer(socket, answer.id, :restore)}
  end

  def handle_event("undo", _, socket), do: {:noreply, socket}

  def handle_event("remove-standing", %{"id" => id}, socket) do
    socket =
      case Answers.remove_standing(id) do
        {:ok, _} -> socket
        {:error, _} -> notice(socket, :failed)
      end

    {:noreply, refresh(socket)}
  rescue
    e ->
      if Foreman.Repo.unavailable?(e),
        do: {:noreply, notice(socket, :failed)},
        else: reraise(e, __STACKTRACE__)
  end

  @impl true
  def handle_info({:archive_expired, token}, socket) do
    socket =
      if socket.assigns.archived && socket.assigns.archived.token == token,
        do: socket |> notice(:clear) |> assign(archived: nil),
        else: socket

    {:noreply, socket}
  end

  defp change_answer(socket, id, event) do
    case Answers.change_state(id, event) do
      {:ok, answer} when event == :archive ->
        token = make_ref()
        Process.send_after(self(), {:archive_expired, token}, 5_000)

        socket
        |> notice(:archive)
        |> assign(archived: %{id: id, question: hd(answer.versions).question, token: token})
        |> refresh()

      {:ok, _} ->
        socket |> notice(:clear) |> assign(archived: nil) |> refresh()

      {:error, _} ->
        notice(socket, :failed)
    end
  rescue
    e ->
      if Foreman.Repo.unavailable?(e),
        do: notice(socket, :failed),
        else: reraise(e, __STACKTRACE__)
  end

  defp notice(socket, event) do
    {state, []} = Answers.Notice.step(socket.assigns.notice, event, %{})
    assign(socket, notice: state, archived: if(state == :archived, do: socket.assigns.archived))
  end

  defp refresh(socket, reveal_link? \\ false) do
    filters =
      if reveal_link? and socket.assigns.tab == :saved and socket.assigns.selected != nil do
        case Answers.get(socket.assigns.selected) do
          %{state: state} when state in [:archived, :archived_pinned] ->
            Map.put(socket.assigns.filters, "archived", "true")

          _ ->
            socket.assigns.filters
        end
      else
        socket.assigns.filters
      end

    answers = Answers.list(filters)
    standing = Answers.standing(filters)
    {yours, your_count} = Answers.yours(filters, socket.assigns.limit)
    {load, []} = Answers.Load.step(socket.assigns.load, :loaded, %{})

    socket
    |> assign(
      load: load,
      filters: filters,
      form: to_form(filters, as: :filters),
      counts: %{saved: length(answers), yours: your_count, rules: length(standing)},
      empty?:
        %{saved: answers == [], yours: yours == [], rules: standing == []}[socket.assigns.tab],
      more?: your_count > socket.assigns.limit
    )
    |> stream(:answers, answers, reset: true)
    |> stream(:standing, standing, reset: true)
    |> stream(:yours, yours, reset: true)
  rescue
    e ->
      if Foreman.Repo.unavailable?(e) do
        {load, []} = Answers.Load.step(socket.assigns.load, :failed, %{})
        assign(socket, :load, load)
      else
        reraise(e, __STACKTRACE__)
      end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:answers}
      pending_count={@pending_count}
      drawer_state={@drawer_state}
      streams={@streams}
    >
      <div class="bb-answers">
        <h1 class="text-2xl font-semibold">Answers</h1>
        <nav aria-label="Answers tabs" class="bb-answer-tabs">
          <.link
            :for={
              {tab, label} <- [saved: "Saved answers", yours: "Your answers", rules: "Always rules"]
            }
            id={"answers-tab-#{tab}"}
            patch={"/answers?tab=#{tab}"}
            aria-current={if @tab == tab, do: "page"}
          >
            {label} <span class="bb-answer-count">{@counts[tab]}</span>
          </.link>
        </nav>
        <.form for={@form} id="answer-filters" phx-change="filter" phx-submit="filter">
          <div class="bb-answer-filters">
            <div class="bb-answer-search">
              <.icon name="hero-magnifying-glass" class="size-4" />
              <.input
                field={@form[:search]}
                type="search"
                label="Search"
                class="bb-filter-control"
                phx-debounce="200"
              />
            </div>
            <.input
              field={@form[:repo]}
              type="select"
              label="Repo"
              class="bb-filter-control"
              options={[{"All repos", ""} | @repos]}
            />
            <.input
              field={@form[:ticket]}
              type="text"
              label="Ticket"
              class="bb-filter-control"
              phx-debounce="200"
            />
          </div>
          <div :if={@tab == :saved} class="bb-answer-archive">
            <.input field={@form[:archived]} type="checkbox" label="Show archived" class="bb-switch" />
          </div>
        </.form>
        <div
          :if={@load == :loading}
          id="answers-loading"
          role="status"
          aria-label="Loading answers…"
          class="space-y-3"
        >
          <div :for={_ <- 1..4} data-skeleton="true" class="bb-answer-skeleton"></div>
        </div>
        <StatusLine.status_line
          :if={@load == :failed}
          id="answers-error"
          kind={:error}
          retry="retry"
          retry_id="answers-retry"
        >
          <strong>Could not load answers.</strong> The database did not answer. Your filters are kept.
        </StatusLine.status_line>
        <div :if={@load == :ready and @empty?} id="no-answers" class="bb-answer-empty">
          <%= if filtered?(@filters, @tab) do %>
            <strong>
              {if @filters["search"] not in [nil, ""],
                do: "No answers match “#{@filters["search"]}”.",
                else: "No answers match these filters."}
            </strong>
            <p :if={@filters["search"] not in [nil, ""]}>
              Search looks in questions and answer text.
            </p>
            <Button.button id="answers-clear" phx-click="clear-filters" size="xs">
              Clear filters
            </Button.button>
          <% else %>
            <%= case @tab do %>
              <% :saved -> %>
                <strong>No saved answers yet.</strong>
                <p>Answers that agents save show here.</p>
              <% :yours -> %>
                <strong>You have not answered a card yet.</strong>
              <% :rules -> %>
                <strong>No Always rules.</strong>
            <% end %>
          <% end %>
        </div>
        <div :if={@tab == :rules} id="standing-answers" phx-update="stream" class="bb-answer-list">
          <article :for={{id, answer} <- @streams.standing} id={id} class="bb-answer-row">
            <div class="flex items-start justify-between gap-4">
              <h2 class="font-semibold">{answer.question}</h2>
              <Button.button
                id={"remove-standing-#{answer.id}"}
                size="xs"
                phx-click="remove-standing"
                phx-value-id={answer.id}
              >
                Remove
              </Button.button>
            </div>
            <p>{answer.answer}</p>
            <p
              :if={answer.note not in [nil, ""]}
              class="whitespace-pre-wrap text-foreground-softer"
              phx-no-format
            >{answer.note}</p>
            <div class="bb-answer-meta">
              <span>{answer.repo_key}</span> <TicketDetail.timestamp at={answer.updated_at} />
            </div>
          </article>
        </div>
        <div :if={@tab == :yours} id="your-answers" phx-update="stream" class="bb-answer-list">
          <article :for={{id, answer} <- @streams.yours} id={id} class="bb-answer-row">
            <h2 class="font-semibold">{answer.facts["question"]}</h2>
            <p>You answered {answer_text(answer)}</p>
            <p
              :if={answer.note not in [nil, ""]}
              class="whitespace-pre-wrap text-foreground-softer"
              phx-no-format
            >“{answer.note}”</p>
            <div class="bb-answer-meta">
              <RequestCard.ticket_link id={id <> "-ticket"} request={answer} link={:navigate} />
              <span :if={answer.session}>
                to
                <.link
                  :if={answer.agent_session_id}
                  navigate={"/sessions/#{answer.agent_session_id}"}
                  class="hover:underline"
                >
                  {answer.session}
                </.link>
                <span :if={!answer.agent_session_id}>{answer.session}</span>
              </span>
              <TicketDetail.timestamp at={answer.updated_at} />
            </div>
          </article>
        </div>
        <Button.button :if={@tab == :yours and @more?} id="answers-more" phx-click="more" size="sm">
          Show 50 more
        </Button.button>
        <div :if={@tab == :saved} id="answers" phx-update="stream" class="bb-answer-list">
          <article :for={{dom_id, answer} <- @streams.answers} id={dom_id} class="bb-answer-row">
            <% latest = hd(answer.versions) %>
            <% pinned = answer.state in [:pinned, :archived_pinned] %>
            <% archived = answer.state in [:archived, :archived_pinned] %>
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0 flex-1">
                <.link
                  id={"expand-#{answer.id}"}
                  patch={
                    if @selected == answer.id,
                      do: "/answers?tab=saved",
                      else: "/answers?id=#{answer.id}"
                  }
                  aria-expanded={to_string(@selected == answer.id)}
                  aria-controls={"answer-body-#{answer.id}"}
                  class="flex items-start gap-2 font-semibold hover:underline"
                >
                  <.icon
                    name={
                      if @selected == answer.id, do: "hero-chevron-down", else: "hero-chevron-right"
                    }
                    class="mt-0.5 size-4 shrink-0"
                  />
                  {latest.question}
                </.link>
                <div class="bb-answer-meta mt-2">
                  <span :if={latest.repo}>{latest.repo}</span>
                  <RequestCard.ticket_link
                    :if={latest.repo && latest.ticket}
                    id={dom_id <> "-ticket"}
                    request={%{repo_key: latest.repo, bead_id: latest.ticket}}
                    link={:navigate}
                  />
                  <span :if={length(answer.versions) > 1}>{length(answer.versions)} versions</span>
                  <TicketDetail.timestamp at={latest.inserted_at} />
                  <span :if={pinned} class="inline-flex items-center gap-1">
                    <.icon name="hero-bookmark" class="size-3.5" />Pinned
                  </span>
                </div>
              </div>
              <div class="bb-answer-actions">
                <span
                  id={"copy-answer-#{answer.id}"}
                  phx-hook="AnswerLink"
                  phx-update="ignore"
                  data-url={"/answers?id=#{answer.id}"}
                >
                  <button
                    type="button"
                    class="bb-iconbtn"
                    title="Copy link"
                    aria-label="Copy link"
                    data-copy="true"
                  >
                    <span data-copy-icon="true"><.icon name="hero-link" class="size-4" /></span>
                    <span data-check-icon="true" class="hidden">
                      <.icon name="hero-check" class="size-4" />
                    </span>
                  </button>
                  <span data-copy-status="true" role="status" class="text-xs"></span>
                </span>
                <button
                  id={"pin-#{answer.id}"}
                  type="button"
                  class="bb-iconbtn"
                  title={if pinned, do: "Unpin", else: "Pin"}
                  aria-label={if pinned, do: "Unpin", else: "Pin"}
                  phx-click="state"
                  phx-value-id={answer.id}
                  phx-value-event={if pinned, do: "unpin", else: "pin"}
                >
                  <.icon
                    name={if pinned, do: "hero-bookmark-solid", else: "hero-bookmark"}
                    class="size-4"
                  /><span class="sr-only">{if pinned, do: "Unpin", else: "Pin"}</span>
                </button>
                <button
                  id={"archive-#{answer.id}"}
                  type="button"
                  class="bb-iconbtn"
                  title={if archived, do: "Restore", else: "Archive"}
                  aria-label={if archived, do: "Restore", else: "Archive"}
                  phx-click="state"
                  phx-value-id={answer.id}
                  phx-value-event={if archived, do: "restore", else: "archive"}
                >
                  <.icon
                    name={if archived, do: "hero-arrow-uturn-left", else: "hero-archive-box"}
                    class="size-4"
                  /><span class="sr-only">{if archived, do: "Restore", else: "Archive"}</span>
                </button>
              </div>
            </div>
            <div :if={@viewer == :open and @selected == answer.id} class="mt-4 space-y-4">
              <div id={"answer-body-#{answer.id}"} class="fm-markdown min-w-0">
                {Phoenix.HTML.raw(render_body(latest.body, latest.repo))}
              </div>
              <.answer_links version={latest} />
              <details
                :if={length(answer.versions) > 1}
                id={"versions-#{answer.id}"}
                class="border-t border-base pt-3"
              >
                <summary class="cursor-pointer text-sm font-semibold">
                  Earlier versions ({length(answer.versions) - 1})
                </summary>
                <div
                  :for={version <- tl(answer.versions)}
                  class="mt-4 space-y-2 border-l-2 border-base pl-4"
                >
                  <h3 class="font-medium">{version.question}</h3>
                  <div class="bb-answer-meta">
                    <span :if={version.repo}>{version.repo}</span><span :if={version.ticket}>{version.ticket}</span>
                    <TicketDetail.timestamp at={version.inserted_at} />
                  </div>
                  <div class="fm-markdown min-w-0">
                    {Phoenix.HTML.raw(render_body(version.body, version.repo))}
                  </div>
                  <.answer_links version={version} />
                </div>
              </details>
            </div>
          </article>
        </div>
        <StatusLine.status_line
          :if={@notice == :archived}
          id="answer-archived"
          kind={:info}
          class="bb-answer-toast"
        >
          Archived “{@archived.question}”.
          <Button.button id="answer-undo" size="xs" phx-click="undo">Undo</Button.button>
        </StatusLine.status_line>
        <StatusLine.status_line
          :if={@notice == :failed}
          id="answer-change-error"
          kind={:error}
          class="bb-answer-toast"
        >
          <strong>Answer not changed.</strong> The answer is not there now.
        </StatusLine.status_line>
      </div>
    </Layouts.app>
    """
  end

  defp filtered?(filters, tab) do
    Enum.any?(["search", "repo", "ticket"], &(filters[&1] not in [nil, ""])) or
      (tab == :saved and filters["archived"] == "true")
  end

  defp answer_text(%{outcome: %{"answer" => []}}), do: "none of the items"

  defp answer_text(%{outcome: %{"answer" => answer}, facts: facts}) when is_list(answer) do
    labels = Map.new(facts["items"] || [], &{&1["id"], &1["label"]})
    Enum.map_join(answer, ", ", &Map.get(labels, &1, &1))
  end

  defp answer_text(%{outcome: %{"answer" => answer}}) when is_binary(answer), do: answer
  defp answer_text(_), do: "with your note"

  attr :version, :map, required: true

  defp answer_links(assigns) do
    assigns =
      assign(
        assigns,
        :links,
        Enum.map(assigns.version.links, &{&1, link_url(&1, assigns.version.repo)})
      )

    ~H"""
    <ul :if={@links != []} class="flex flex-wrap gap-3" aria-label="Links">
      <li :for={{label, url} <- @links} class="min-w-0">
        <.link :if={url} href={url} class="underline underline-offset-4">
          <ForemanWeb.LongText.path text={label} />
        </.link>
        <ForemanWeb.LongText.path :if={!url} text={label} class="text-foreground-softer" />
      </li>
    </ul>
    """
  end

  defp render_body(body, repo) do
    links =
      body |> Markdown.path_candidates() |> Enum.take(50) |> Map.new(&{&1, link_url(&1, repo)})

    Markdown.render(body,
      header_ids: false,
      link_paths: &Map.get(links, &1),
      resolve_path: &link_url(&1, repo)
    )
  end

  defp link_url(link, repo) do
    uri = URI.parse(link)

    if uri.scheme in ["https", "http"] and is_binary(uri.host) do
      link
    else
      case CardText.resolve(link, repo, CardText.repos()) do
        {key, path} ->
          Markdown.viewer_path(key, path)

        nil ->
          case CardText.docs([link], repo) do
            {:ok, [%{"repo" => key, "path" => path}]} -> Markdown.viewer_path(key, path)
            _ -> nil
          end
      end
    end
  end
end
