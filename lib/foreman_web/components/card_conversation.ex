defmodule ForemanWeb.CardConversation do
  @moduledoc """
  A request's durable Markdown thread: the questions asked with Ask about this and
  the replies. It shows only when the card has messages. The Ask about this box
  lives in the card footer (`ForemanWeb.OpenCard`).
  """
  use ForemanWeb, :live_component

  # Each card owns a stream so a long thread is not retained in the page's assigns.
  def update_many(assigns_sockets) do
    ids = Enum.map(assigns_sockets, fn {assigns, _} -> assigns.request.id end)
    messages = Foreman.CardMessages.list_many(ids)

    Enum.map(assigns_sockets, fn {assigns, socket} ->
      update_conversation(assigns, socket, Map.get(messages, assigns.request.id, []))
    end)
  end

  defp update_conversation(assigns, socket, messages) do
    socket =
      socket
      |> assign(Map.merge(%{prefix: "", repos: nil, class: nil}, assigns))
      |> assign(empty?: messages == [])

    socket =
      if socket.assigns[:streams],
        do: socket,
        else:
          stream_configure(socket, :messages,
            dom_id: &(socket.assigns.prefix <> "card-message-" <> to_string(&1.id))
          )

    stream(socket, :messages, messages, reset: true)
  end

  def render(assigns) do
    ~H"""
    <section id={@id} class={[@empty? && "hidden", @class]}>
      <div
        id={@id <> "-messages"}
        phx-update="stream"
        class="space-y-3 rounded-lg border border-base bg-base p-4"
      >
        <div
          :for={{id, message} <- @streams.messages}
          id={id}
          data-card-message
          class="space-y-2 border-b border-base pb-3 last:border-0 last:pb-0"
        >
          <div class="flex items-center justify-between gap-3 text-xs text-foreground-softer">
            <span data-card-message-author>{Foreman.CardMessages.author_name(message.author)}</span>
            <ForemanWeb.TicketDetail.timestamp at={message.inserted_at} />
          </div>
          <ForemanWeb.RequestCard.agent_text
            id={@prefix <> "card-message-body-" <> to_string(message.id)}
            text={message.body}
            repo={@request.repo_key}
            repos={@repos}
          />
        </div>
      </div>
    </section>
    """
  end
end
