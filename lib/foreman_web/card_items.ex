defmodule ForemanWeb.CardItems do
  @moduledoc """
  The open cards in a page stream (Needs you or the request drawer). A stream
  item cannot be read back, so each card's own state is kept by card id in two
  assigns and every insert builds the full item from them:

  - the card's notices: the session-waiting notice (`Foreman.WaitingCard`), the
    last Focus terminal result and the last Ask about this send;
  - its footer (`ForemanWeb.CardFooter`): the open panel and the panel text.

  `opts` name the host's assigns: `:stream`, `:ui`, `:footers`, `:headings` and
  the DOM `:prefix` of its cards.
  """
  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [stream_insert: 3, push_event: 3]
  alias ForemanWeb.CardFooter
  alias Foreman.{CardFooterPanel, Requests}

  @ready %{card: :ready, focus: :ready, question: :ready}

  def assigns(socket, opts),
    do: socket |> assign(opts[:ui], %{}) |> assign(opts[:footers], %{})

  @doc "The stream item for `request`, with its kept notices and footer."
  def item(socket, opts, request, heading) do
    ui = Map.get(socket.assigns[opts[:ui]], request.id, @ready)

    Map.merge(ui, %{
      id: request.id,
      request: request,
      heading: heading,
      footer: CardFooter.get(socket.assigns[opts[:footers]], request.id)
    })
  end

  @doc "Inserts `items` (from `ForemanWeb.NeedsYouLive.grouped/1`) with their kept state."
  def with_state(socket, opts, items),
    do: Enum.map(items, &item(socket, opts, &1.request, &1.heading))

  @doc "Forgets the state of cards that are no longer pending."
  def prune(socket, opts, ids) do
    socket
    |> update(opts[:ui], &Map.filter(&1, fn {id, _} -> MapSet.member?(ids, id) end))
    |> update(opts[:footers], &CardFooter.prune(&1, ids))
  end

  @doc """
  Keeps a card notice from `ForemanWeb.NeedsYouLive.resolve/1`: `{:focus, state}`,
  `{:question, state}` or a session-waiting state. The newest notice replaces the
  card's other notices.
  """
  def notice(socket, opts, id, notice) do
    {key, value} =
      case notice do
        {:focus, state} -> {:focus, state}
        {:question, state} -> {:question, state}
        state -> {:card, state}
      end

    socket = update(socket, opts[:ui], &Map.put(&1, id, Map.put(@ready, key, value)))

    socket =
      case value do
        {_, text} when key == :question -> keep(socket, opts, id, :ask, text)
        _ -> socket
      end

    reinsert(socket, opts, id)
  end

  @doc "After a card action: a sent question closes the Ask panel (`question_sent`)."
  def sent(socket, opts, %{"id" => id, "action" => "card-question"}, {:ok, _}),
    do: question_sent(socket, opts, id)

  def sent(socket, _, _, _), do: socket

  @doc "A question was sent from the card: the Ask panel closes and its text clears."
  def question_sent(socket, opts, id) do
    case CardFooter.step(socket.assigns[opts[:footers]], id, :question_sent) do
      {footers, _} ->
        socket
        |> assign(opts[:footers], footers)
        |> update(opts[:ui], &Map.update(&1, id, @ready, fn ui -> %{ui | question: :ready} end))
        |> reinsert(opts, id)

      :error ->
        socket
    end
  end

  @doc "A footer text action: toggles its panel (P1) and scrolls the card up (P2)."
  def toggle(socket, opts, %{"id" => id, "panel" => name}) do
    with panel when not is_nil(panel) <- CardFooterPanel.panel(name),
         {footers, effects} <-
           CardFooter.step(socket.assigns[opts[:footers]], id, {:toggle, panel}) do
      socket = socket |> assign(opts[:footers], footers) |> reinsert(opts, id)

      if Keyword.has_key?(effects, :scroll_to_top),
        do: push_event(socket, "card-scroll-top", %{id: opts[:prefix] <> "card-open-" <> id}),
        else: socket
    else
      _ -> socket
    end
  end

  def toggle(socket, _, _), do: socket

  @doc "Panel text as you type. The Ask copy field shows the text, so that card redraws."
  def text(socket, opts, %{"card" => id, "panel" => name} = params) do
    panel = CardFooterPanel.panel(name)

    case panel && text_param(panel, params) do
      text when is_binary(text) ->
        socket = keep(socket, opts, id, panel, text)
        if panel == :ask, do: reinsert(socket, opts, id), else: socket

      _ ->
        socket
    end
  end

  def text(socket, _, _), do: socket

  defp keep(socket, opts, id, panel, text),
    do: update(socket, opts[:footers], &CardFooter.keep_text(&1, id, panel, text))

  defp text_param(:ask, params), do: get_in(params, ["card_question", "text"])
  defp text_param(:wrong_question, params), do: get_in(params, ["wrong_question", "reason"])
  defp text_param(:withdraw, params), do: get_in(params, ["withdraw", "reason"])

  @doc "Redraws one card from the database; returns the socket unchanged if it left."
  def reinsert(socket, opts, id) do
    case Requests.get(id) do
      %{state: "pending"} = request ->
        [request] = Requests.with_priority([request])
        heading = MapSet.member?(socket.assigns[opts[:headings]], id)
        stream_insert(socket, opts[:stream], item(socket, opts, request, heading))

      _ ->
        socket
    end
  end
end
