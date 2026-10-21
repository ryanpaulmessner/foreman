defmodule ForemanWeb.AnswersLive do
  use ForemanWeb, :live_view
  alias Foreman.{Answers, CardText, Markdown}
  alias ForemanWeb.TicketDetail
  alias Fluxon.Components.Button

  @impl true
  def mount(_, _, socket) do
    {:ok,
     assign(socket,
       viewer: Answers.Expansion.__fsm__(:initial),
       selected: nil,
       filters: %{},
       form: to_form(%{}, as: :filters)
     )}
  end

  @impl true
  def handle_params(params, _, socket) do
    selected = params["id"]

    {viewer, []} =
      Answers.Expansion.step(
        socket.assigns.viewer,
        if(selected, do: :expand, else: :collapse),
        %{}
      )

    {:noreply, socket |> assign(selected: selected, viewer: viewer) |> refresh()}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    filters = Map.take(filters, ["search", "repo", "ticket", "archived"])

    {:noreply,
     socket |> assign(filters: filters, form: to_form(filters, as: :filters)) |> refresh()}
  end

  def handle_event("state", %{"id" => id, "event" => event}, socket)
      when event in ["pin", "unpin", "archive", "restore"] do
    event =
      %{"pin" => :pin, "unpin" => :unpin, "archive" => :archive, "restore" => :restore}[event]

    socket =
      case Answers.change_state(id, event) do
        {:ok, _} -> socket
        {:error, _} -> put_flash(socket, :error, "Answer unavailable")
      end

    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    stream(socket, :answers, Answers.list(socket.assigns.filters),
      reset: true,
      dom_id: &"answer-#{&1.id}"
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:answers}
      pending_count={@pending_count}
      drawer_state={@drawer_state}
      drawer_error={@drawer_error}
      streams={@streams}
    >
      <div class="mx-auto w-full max-w-4xl space-y-6 p-4 sm:p-8">
        <h1 class="text-2xl font-semibold">Answers</h1>
        <.form
          for={@form}
          id="answer-filters"
          phx-change="filter"
          phx-submit="filter"
          class="grid gap-3 sm:grid-cols-3"
        >
          <.input field={@form[:search]} type="search" label="Search" phx-debounce="200" />
          <.input field={@form[:repo]} type="text" label="Repo" phx-debounce="200" />
          <.input field={@form[:ticket]} type="text" label="Ticket" phx-debounce="200" />
          <.input field={@form[:archived]} type="checkbox" label="Show archived" />
        </.form>
        <div id="answers" phx-update="stream" class="space-y-3">
          <p id="no-answers" class="hidden only:block py-8 text-foreground-softer">No answers</p>
          <article
            :for={{dom_id, answer} <- @streams.answers}
            id={dom_id}
            class="min-w-0 rounded-xl border border-base bg-base p-4 sm:p-6"
          >
            <% latest = hd(answer.versions) %>
            <div class="flex items-start justify-between gap-4">
              <.link
                id={"expand-#{answer.id}"}
                patch={if @selected == answer.id, do: "/answers", else: "/answers?id=#{answer.id}"}
                aria-expanded={to_string(@selected == answer.id)}
                aria-controls={"answer-body-#{answer.id}"}
                class="min-w-0 break-words text-base font-semibold hover:underline"
              >
                {latest.question}
              </.link>
            </div>
            <div class="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-foreground-softer">
              <span :if={latest.repo}>{latest.repo}</span>
              <span :if={latest.ticket}>{latest.ticket}</span>
              <span>{latest.actor}</span>
              <span :if={latest.session} class="break-all">{latest.session}</span>
              <TicketDetail.timestamp at={latest.inserted_at} />
            </div>
            <div class="mt-3 flex gap-2">
              <Button.button
                id={"pin-#{answer.id}"}
                size="xs"
                variant="outline"
                phx-click="state"
                phx-value-id={answer.id}
                phx-value-event={
                  if answer.state in [:pinned, :archived_pinned], do: "unpin", else: "pin"
                }
              >
                {if answer.state in [:pinned, :archived_pinned], do: "Unpin", else: "Pin"}
              </Button.button>
              <Button.button
                id={"archive-#{answer.id}"}
                size="xs"
                variant="outline"
                phx-click="state"
                phx-value-id={answer.id}
                phx-value-event={
                  if answer.state in [:archived, :archived_pinned], do: "restore", else: "archive"
                }
              >
                {if answer.state in [:archived, :archived_pinned], do: "Restore", else: "Archive"}
              </Button.button>
            </div>
            <div :if={@viewer == :open and @selected == answer.id} class="mt-6 space-y-6">
              <div id={"answer-body-#{answer.id}"} class="fm-markdown min-w-0 break-words">
                {Phoenix.HTML.raw(render_body(latest.body, latest.repo))}
              </div>
              <.answer_links version={latest} />
              <section
                :if={length(answer.versions) > 1}
                id={"versions-#{answer.id}"}
                class="space-y-4 border-t border-base pt-4"
              >
                <h2 class="text-sm font-semibold">
                  Earlier versions ({length(answer.versions) - 1})
                </h2>
                <div
                  :for={version <- tl(answer.versions)}
                  class="space-y-2 border-l-2 border-base pl-4"
                >
                  <h3 class="font-medium break-words">{version.question}</h3>
                  <div class="flex gap-3 text-xs text-foreground-softer">
                    <span>{version.actor}</span>
                    <span :if={version.session} class="break-all">{version.session}</span>
                    <span :if={version.repo}>{version.repo}</span>
                    <span :if={version.ticket}>{version.ticket}</span>
                    <TicketDetail.timestamp at={version.inserted_at} />
                  </div>
                  <div class="fm-markdown min-w-0 break-words">
                    {Phoenix.HTML.raw(render_body(version.body, version.repo))}
                  </div>
                  <.answer_links version={version} />
                </div>
              </section>
            </div>
          </article>
        </div>
      </div>
    </Layouts.app>
    """
  end

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
      <li :for={{label, url} <- @links} class="min-w-0 break-all">
        <.link :if={url} href={url} class="underline underline-offset-4">{label}</.link>
        <span :if={!url} class="text-foreground-softer">{label}</span>
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
