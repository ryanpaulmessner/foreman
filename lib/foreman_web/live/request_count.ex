defmodule ForemanWeb.RequestCount do
  @moduledoc "Shared authoritative inbox count; mount, notifications and periodic reconciliation."
  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:default, _, _, socket) do
    if connected?(socket) do
      Foreman.Events.subscribe()
      Process.send_after(self(), :request_count_tick, 3_000)
    end

    {:cont,
     socket
     |> ForemanWeb.RequestDrawer.mount()
     |> refresh()
     |> attach_hook(:request_count_params, :handle_params, fn _, _, socket ->
       {:cont, refresh(socket)}
     end)
     |> attach_hook(:request_count, :handle_info, &handle_info/2)
     |> attach_hook(:notification_sync, :handle_event, fn
       "notification_sync", _, socket ->
         {:halt, %{requests: notification_requests(Foreman.Requests.pending())}, socket}

       _, _, socket ->
         {:cont, socket}
     end)}
  end

  # When the database does not answer, the count stays as it was.
  def refresh(socket) do
    case pending() do
      {:ok, pending} -> refresh(socket, pending)
      :error -> socket
    end
  end

  defp pending do
    {:ok, Foreman.Requests.pending()}
  rescue
    e -> if Foreman.Repo.unavailable?(e), do: :error, else: reraise(e, __STACKTRACE__)
  end

  defp refresh(socket, pending) do
    count = length(pending)

    socket
    |> assign(
      pending_count: count,
      page_title: if(count > 0, do: "(#{count}) foreman", else: "foreman")
    )
    |> push_event("notification_snapshot", %{requests: notification_requests(pending)})
    |> ForemanWeb.RequestDrawer.refresh(pending)
  end

  defp notification_requests(pending) do
    Enum.map(pending, fn request ->
      %{id: request.id, kind: request.kind, ticket: request.bead_id}
    end)
  end

  defp handle_info(:request_count_tick, socket) do
    Process.send_after(self(), :request_count_tick, 3_000)
    {:halt, refresh(socket)}
  end

  defp handle_info({:notification, :foreman_events, _}, socket), do: {:cont, refresh(socket)}
  defp handle_info(_, socket), do: {:cont, socket}
end
