defmodule ForemanWeb.NeedsYouLive do
  use ForemanWeb, :live_view
  alias Foreman.Requests
  alias Fluxon.Components.{Button, Badge}

  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :reconcile, 3_000)

    {:ok,
     socket
     |> assign(:pending_ids, MapSet.new())
     |> stream_configure(:pending, dom_id: &("request-" <> &1.id))
     |> stream(:pending, [])
     |> refresh()}
  end

  def handle_params(params, uri, socket),
    do: {:noreply, ForemanWeb.TicketDetail.load(socket, params, uri)}

  def handle_event("resolve", params, socket), do: {:noreply, result(socket, resolve(params))}

  def handle_event("close-ticket", params, socket),
    do: {:noreply, ForemanWeb.TicketDetail.close(socket, params)}

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
  def item(request, card \\ Foreman.WaitingCard.__fsm__(:initial)),
    do: %{id: request.id, request: request, card: card}

  def handle_info(:reconcile, socket) do
    Process.send_after(self(), :reconcile, 3_000)
    {:noreply, socket |> refresh() |> ForemanWeb.TicketDetail.refresh()}
  end

  def handle_info({:notification, :foreman_events, _}, socket),
    do: {:noreply, socket |> refresh() |> ForemanWeb.TicketDetail.refresh()}

  defp result(socket, {:navigate, path}), do: push_navigate(socket, to: path)

  defp result(socket, {:card, id, card}) do
    case Requests.get(id) do
      %{state: "pending"} = request -> stream_insert(socket, :pending, item(request, card))
      _ -> refresh(socket)
    end
  end

  defp result(socket, {:ok, _}), do: refresh(socket)

  defp result(socket, {:error, _}),
    do: socket |> put_flash(:error, "Request not updated") |> refresh()

  defp refresh(socket) do
    pending = Requests.pending()
    ids = MapSet.new(pending, & &1.id)
    previous = socket.assigns.pending_ids

    # Pending facts are immutable. Leave existing cards mounted so reconciliation
    # cannot erase an answer or note the user is still composing.
    socket =
      Enum.reduce(MapSet.difference(previous, ids), socket, fn id, socket ->
        stream_delete_by_dom_id(socket, :pending, "request-" <> id)
      end)

    socket =
      pending
      |> Enum.with_index()
      |> Enum.reduce(socket, fn {request, index}, socket ->
        if MapSet.member?(previous, request.id),
          do: socket,
          else: stream_insert(socket, :pending, item(request), at: index)
      end)

    socket
    |> assign(:pending_ids, ids)
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
          />
        </div>
      </details>
      <ForemanWeb.TicketDetail.sheet
        ticket={@ticket}
        state={@sheet_state}
        return_to={@sheet_return}
        streams={@streams}
        tab={@ticket_tab}
        uri={@page_uri}
      />
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :request, :any, required: true

  attr :prefix, :string, default: ""
  attr :event, :string, default: "resolve"
  attr :card, :atom, default: :ready

  def request_card(%{request: %{kind: kind}} = assigns) when kind in ["push", "open_pr", "merge"],
    do: action_card(assigns)

  def request_card(%{request: %{kind: "session_waiting"}} = assigns), do: waiting_card(assigns)
  def request_card(assigns), do: decision_card(assigns)

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
      <div class="mb-4 flex flex-wrap items-center gap-2 text-xs text-foreground-softer">
        <Badge.badge>Session waiting</Badge.badge>
        <.link
          navigate={"/needs-you?" <> URI.encode_query(%{"ticket" => @request.repo_key <> ":" <> @request.bead_id})}
          class="font-mono hover:underline"
        >
          {@request.bead_id}
        </.link>
        <span class="ml-auto"><ForemanWeb.TicketDetail.timestamp at={@request.inserted_at} /></span>
      </div>
      <ForemanWeb.RequestCard.waiting_facts request={@request} />
      <%= if @question do %>
        <h3
          id={@prefix <> "question-" <> @request.id}
          class="mt-4 whitespace-pre-wrap break-words font-medium"
          phx-no-format
        >{@question["question"]}</h3>
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
        <p
          id={@prefix <> "chat-question-" <> @request.id}
          class="mt-4 max-h-64 overflow-y-auto whitespace-pre-wrap break-words font-medium [overflow-wrap:anywhere]"
          phx-no-format
        >{@request.facts["question"]}</p>
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
          <li :for={question <- @request.facts["questions"]} class="space-y-1">
            <p class="whitespace-pre-wrap break-words font-medium" phx-no-format>{question["question"]}</p>
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
      <div class="mb-4 flex flex-wrap items-center gap-2 text-xs text-foreground-softer">
        <Badge.badge>
          {%{"push" => "Push", "open_pr" => "Open PR", "merge" => "Merge"}[@request.kind]}
        </Badge.badge>
        <.link
          patch={
            if @prefix == "",
              do:
                "/needs-you?" <>
                  URI.encode_query(%{"ticket" => @request.repo_key <> ":" <> @request.bead_id})
          }
          navigate={
            if @prefix != "",
              do:
                "/needs-you?" <>
                  URI.encode_query(%{"ticket" => @request.repo_key <> ":" <> @request.bead_id})
          }
          class="font-mono hover:underline"
        >
          {@request.bead_id}
        </.link>
        <span>{@request.actor}<span :if={@request.session}> · {@request.session}</span></span>
        <span class="ml-auto"><ForemanWeb.TicketDetail.timestamp at={@request.inserted_at} /></span>
      </div>
      <ForemanWeb.RequestCard.push_facts :if={@request.kind == "push"} request={@request} />
      <ForemanWeb.RequestCard.open_pr_facts :if={@request.kind == "open_pr"} request={@request} />
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
      <div class="mb-4 flex flex-wrap items-center gap-2 text-xs text-foreground-softer">
        <Badge.badge>Decision</Badge.badge>
        <.link
          patch={
            if @prefix == "",
              do:
                "/needs-you?" <>
                  URI.encode_query(%{"ticket" => @request.repo_key <> ":" <> @request.bead_id})
          }
          navigate={
            if @prefix != "",
              do:
                "/needs-you?" <>
                  URI.encode_query(%{"ticket" => @request.repo_key <> ":" <> @request.bead_id})
          }
          class="font-mono hover:underline"
        >
          {@request.bead_id}
        </.link>
        <span>{@request.actor}<span :if={@request.session}> · {@request.session}</span></span>
        <span class="ml-auto"><ForemanWeb.TicketDetail.timestamp at={@request.inserted_at} /></span>
      </div>
      <h2 class="break-words text-lg font-semibold">{@request.facts["question"]}</h2>
      <p
        :if={@request.facts["text"]}
        class="mt-2 whitespace-pre-wrap break-words text-foreground-softer"
        phx-no-format
      >{@request.facts["text"]}</p>
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
            <span class="min-w-0 flex-1 break-words">{option}</span>
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
