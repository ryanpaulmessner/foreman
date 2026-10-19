defmodule ForemanWeb.RequestDrawer do
  @moduledoc "Shared shell drawer, using the inbox's cards and resolution handler."
  use ForemanWeb, :html
  import Phoenix.LiveView
  alias Fluxon.Components.Sheet

  def mount(socket) do
    socket
    |> assign(
      drawer_state: Foreman.RequestDrawer.__fsm__(:initial),
      drawer_ids: MapSet.new(),
      drawer_error: nil
    )
    |> stream_configure(:drawer_requests, dom_id: &("drawer-request-" <> &1.id))
    |> stream(:drawer_requests, [])
    |> attach_hook(:request_drawer, :handle_event, &handle_event/3)
  end

  def refresh(socket, pending) do
    if socket.assigns.drawer_state == :open do
      ids = MapSet.new(pending, & &1.id)
      previous = socket.assigns.drawer_ids

      socket =
        Enum.reduce(MapSet.difference(previous, ids), socket, fn id, socket ->
          stream_delete_by_dom_id(socket, :drawer_requests, "drawer-request-" <> id)
        end)

      pending
      |> Enum.with_index()
      |> Enum.reduce(socket, fn {request, index}, socket ->
        if MapSet.member?(previous, request.id),
          do: socket,
          else:
            stream_insert(socket, :drawer_requests, ForemanWeb.NeedsYouLive.item(request),
              at: index
            )
      end)
      |> assign(:drawer_ids, ids)
    else
      socket
    end
  end

  defp handle_event("open-request-drawer", _, socket) do
    {:halt, socket |> transition(:open) |> refresh(Foreman.Requests.pending())}
  end

  defp handle_event("close-request-drawer", _, socket),
    do: {:halt, transition(socket, :close)}

  defp handle_event("drawer-resolve", params, socket) do
    socket =
      case ForemanWeb.NeedsYouLive.resolve(params) do
        {:navigate, path} ->
          push_navigate(socket, to: path)

        {:ok, _} ->
          assign(socket, :drawer_error, nil)

        {:card, id, card} ->
          case Foreman.Requests.get(id) do
            %{state: "pending"} = request ->
              socket
              |> assign(:drawer_error, nil)
              |> stream_insert(:drawer_requests, ForemanWeb.NeedsYouLive.item(request, card))

            _ ->
              socket
          end

        {:error, _} ->
          assign(socket, :drawer_error, "Request not updated")
      end

    {:halt, ForemanWeb.RequestCount.refresh(socket)}
  end

  defp handle_event(_, _, socket), do: {:cont, socket}

  defp transition(socket, event) do
    {state, []} = Foreman.RequestDrawer.step(socket.assigns.drawer_state, event, %{})
    assign(socket, drawer_state: state, drawer_error: nil)
  end

  attr :state, :atom, required: true
  attr :streams, :map, required: true
  attr :error, :string, default: nil

  def drawer(assigns) do
    ~H"""
    <Sheet.sheet
      id="request-drawer"
      open={@state == :open}
      placement="right"
      class="w-[min(640px,100vw)] space-y-5 [scrollbar-gutter:stable]"
      on_close={JS.push("close-request-drawer")}
    >
      <header class="space-y-2 pr-8">
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
        <.link
          id="drawer-full-page"
          navigate="/needs-you"
          class="text-sm text-foreground-softer underline"
        >
          Open full page
        </.link>
      </header>
      <p
        :if={@error}
        id="drawer-error"
        role="alert"
        class="rounded-lg border border-base bg-sunken p-3 text-sm"
      >
        {@error}
      </p>
      <div id="drawer-requests" phx-update="stream" class="space-y-5">
        <div
          id="drawer-empty"
          class="hidden only:block rounded-xl border border-dashed border-base p-8 text-center text-foreground-softer"
        >
          No pending requests
        </div>
        <ForemanWeb.NeedsYouLive.request_card
          :for={{id, item} <- @streams.drawer_requests}
          id={id}
          request={item.request}
          card={item.card}
          prefix="drawer-"
          event="drawer-resolve"
        />
      </div>
    </Sheet.sheet>
    """
  end
end
