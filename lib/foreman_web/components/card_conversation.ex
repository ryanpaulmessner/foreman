defmodule ForemanWeb.CardConversation do
  @moduledoc "A request's question box and durable Markdown conversation."
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
      |> assign(Map.merge(%{prefix: "", event: "resolve", card: :ready, repos: nil}, assigns))
      |> assign(
        source:
          if(assigns.request.state == "pending",
            do: Foreman.RequestSource.for_request(assigns.request)
          ),
        empty?: messages == []
      )
      |> assign_new(:form, fn -> to_form(%{"text" => ""}, as: :card_question) end)

    socket =
      case socket.assigns.card do
        {state, text} ->
          assign(socket, card: state, form: to_form(%{"text" => text}, as: :card_question))

        _ ->
          socket
      end

    socket =
      if socket.assigns[:streams],
        do: socket,
        else:
          stream_configure(socket, :messages,
            dom_id: &(socket.assigns.prefix <> "card-message-" <> to_string(&1.id))
          )

    stream(socket, :messages, messages, reset: true)
  end

  def handle_event("retry", _, socket) do
    {state, []} = Foreman.WaitingCard.step(socket.assigns.card, :retry, %{})

    {:noreply,
     assign(socket,
       card: state,
       source: Foreman.RequestSource.for_request(socket.assigns.request)
     )}
  end

  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class={[
        (@empty? and @request.state != "pending") && "hidden",
        "space-y-3 rounded-lg border border-base bg-base p-4"
      ]}
    >
      <div id={@id <> "-messages"} phx-update="stream" class="space-y-3">
        <div
          :for={{id, message} <- @streams.messages}
          id={id}
          data-card-message
          class="space-y-2 border-b border-base pb-3 last:border-0"
        >
          <div class="flex items-center justify-between gap-3 text-xs text-foreground-softer">
            <span>{if message.author == "ryan", do: "Ryan", else: message.author}</span>
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
      <div :if={@request.state == "pending"} id={@prefix <> "card-question-" <> @request.id}>
        <%= if @source || @form[:text].value != "" do %>
          <.form
            for={@form}
            id={@prefix <> "card-question-form-" <> @request.id}
            phx-submit={@event}
            phx-value-id={@request.id}
            phx-value-action="card-question"
            class="space-y-3"
          >
            <.input
              field={@form[:text]}
              id={@prefix <> "card-question-text-" <> @request.id}
              type="textarea"
              label="Ask about this"
              maxlength="1900"
              rows="2"
              required
            />
            <button
              :if={@card == :ready and @source}
              id={@prefix <> "card-question-send-" <> @request.id}
              type="submit"
              phx-disable-with="Sending…"
              class="rounded-md border border-base px-3 py-2 text-sm transition hover:bg-sunken"
            >
              Send question
            </button>
          </.form>
        <% else %>
          <h3 class="text-sm font-medium">Ask about this</h3>
        <% end %>
        <%= if is_nil(@source) or @card != :ready do %>
          <button
            id={@prefix <> "card-question-retry-" <> @request.id}
            type="button"
            phx-click="retry"
            phx-target={@myself}
            class="mt-2 rounded-md border border-base px-3 py-2 text-sm transition hover:bg-sunken"
          >
            Try again
          </button>
          <p
            id={@prefix <> "card-question-unavailable-" <> @request.id}
            role="status"
            class="mt-2 text-sm text-foreground-softer"
          >
            {cond do
              is_nil(@source) ->
                "Source unknown. Copy the question to the agent's chat."

              @card == :window_gone ->
                "The session window is closed. The question was not sent."

              @card == :prompt_busy ->
                "The session is not at an empty prompt. The question was not sent."

              true ->
                "Cannot send to the session. The question was not sent."
            end}
          </p>
          <code
            id={@prefix <> "card-question-copy-" <> @request.id}
            class="mt-2 block select-all break-all rounded bg-sunken p-2 text-xs"
          >
            {"[card question #{@request.id}] #{@form[:text].value}"}
          </code>
          <div :if={@source} class="mt-2 text-sm">
            <p>Copy this command to your terminal.</p>
            <code class="block select-all break-all rounded bg-sunken p-2 text-xs">
              {Foreman.RequestSource.command(@source)}
            </code>
          </div>
        <% end %>
      </div>
    </section>
    """
  end
end
