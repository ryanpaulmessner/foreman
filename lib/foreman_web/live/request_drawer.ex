defmodule ForemanWeb.RequestDrawer do
  @moduledoc "Shared shell drawer: pending rows that open a card on Needs you."
  use ForemanWeb, :html
  import Phoenix.LiveView
  alias Fluxon.Components.{Badge, Sheet}

  def mount(socket) do
    socket
    |> assign(drawer_state: Foreman.RequestDrawer.__fsm__(:initial))
    |> stream_configure(:drawer_requests, dom_id: &("drawer-row-" <> &1.id))
    |> stream(:drawer_requests, [])
    |> attach_hook(:request_drawer, :handle_event, &handle_event/3)
  end

  def refresh(socket, pending) do
    if socket.assigns.drawer_state == :open do
      rows =
        pending
        |> ForemanWeb.NeedsYouLive.grouped()
        |> Enum.map(fn %{request: request} ->
          %{
            id: request.id,
            request: request,
            source: Foreman.RequestSource.view(request),
            question: question(request)
          }
        end)

      stream(socket, :drawer_requests, rows, reset: true)
    else
      socket
    end
  end

  defp handle_event("open-request-drawer", _, socket) do
    {:halt, socket |> transition(:open) |> refresh(Foreman.Requests.pending())}
  end

  defp handle_event("close-request-drawer", _, socket),
    do: {:halt, transition(socket, :close)}

  defp handle_event("drawer-open-card", %{"id" => id}, socket) do
    socket = transition(socket, :close)

    socket =
      if socket.view == ForemanWeb.NeedsYouLive do
        ForemanWeb.NeedsYouLive.open_from_drawer(socket, id)
      else
        push_navigate(socket, to: "/needs-you?" <> URI.encode_query(%{"card" => id}))
      end

    {:halt, socket}
  end

  defp handle_event(_, _, socket), do: {:cont, socket}

  defp transition(socket, event) do
    {state, []} = Foreman.RequestDrawer.step(socket.assigns.drawer_state, event, %{})
    assign(socket, :drawer_state, state)
  end

  defp question(%{kind: "session_waiting"} = request) do
    get_in(request.facts, ["questions", Access.at(0), "question"]) ||
      request.facts["question"] || Foreman.RequestHeader.title(request)
  end

  defp question(request), do: request.facts["question"] || Foreman.RequestHeader.title(request)

  attr :state, :atom, required: true
  attr :streams, :map, required: true
  attr :count, :integer, required: true

  def drawer(assigns) do
    ~H"""
    <Sheet.sheet
      id="request-drawer"
      open={@state == :open}
      placement="right"
      class="w-[min(640px,100vw)] space-y-5 [scrollbar-gutter:stable]"
      on_close={JS.push("close-request-drawer")}
    >
      <header class="flex flex-wrap items-center gap-3 pr-8">
        <h2
          id="request-drawer-title"
          tabindex="-1"
          autofocus
          class="text-xl font-semibold outline-none"
          phx-mounted={
            JS.set_attribute({"aria-labelledby", "request-drawer-title"},
              to: "#request-drawer [role=dialog]"
            )
          }
        >
          Needs you
        </h2>
        <Badge.badge id="drawer-count">{@count}</Badge.badge>
        <.link
          id="drawer-full-page"
          navigate="/needs-you"
          phx-click="close-request-drawer"
          class="ml-auto text-sm text-foreground-softer underline"
        >
          Open full page
        </.link>
      </header>
      <div id="drawer-requests" phx-update="stream" class="bb-drawer-list">
        <div
          id="drawer-empty"
          class="hidden only:block rounded-xl border border-dashed border-base p-8 text-center text-foreground-softer"
        >
          No pending requests
        </div>
        <div :for={{id, item} <- @streams.drawer_requests} id={id} class="bb-drawer-row">
          <div class="bb-drawer-meta">
            <Badge.badge>{ForemanWeb.OpenCard.kind_label(item.request.kind)}</Badge.badge>
            <span class="bb-drawer-source" id={"drawer-card-source-" <> item.id}>
              <span class={["bb-dot", item.source.state != :live && "bb-dot-grey"]} aria-hidden="true">
              </span>
              <.link :if={item.source.link} navigate={item.source.link} class="bb-drawer-source-link">
                {item.source.name}
              </.link>
              <span :if={!item.source.link}>{item.source.name || "source unknown"}</span>
              <span :if={item.source.state == :ended}>· ended</span>
            </span>
            <span class="bb-drawer-age">
              <ForemanWeb.TicketDetail.timestamp at={item.request.inserted_at} />
            </span>
          </div>
          <p id={"drawer-question-" <> item.id} class="bb-drawer-question">{item.question}</p>
          <button
            id={"drawer-open-" <> item.id}
            type="button"
            class="bb-drawer-open"
            aria-labelledby={"drawer-open-label-#{item.id} drawer-question-#{item.id}"}
            phx-click="drawer-open-card"
            phx-value-id={item.id}
          >
            <span id={"drawer-open-label-" <> item.id}>Open</span>
          </button>
        </div>
      </div>
    </Sheet.sheet>
    """
  end
end
