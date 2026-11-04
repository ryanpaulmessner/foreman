defmodule ForemanWeb.CardItems do
  @moduledoc """
  The open cards in a page stream (Needs you or the request drawer). A stream
  item cannot be read back, so each card's own state is kept by card id in two
  assigns and every insert builds the full item from them:

  - the card's notices: the session-waiting notice (`Foreman.WaitingCard`) and
    the last Focus terminal result;
  - its footer (`ForemanWeb.CardFooter`): the text box and the Ask state.

  `opts` name the host's assigns: `:stream`, `:ui`, `:footers` and `:headings`.
  """
  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [stream_insert: 3]
  alias ForemanWeb.CardFooter
  alias Foreman.Requests

  @ready %{card: :ready, focus: :ready}

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

  @doc "Builds `items` (from `ForemanWeb.NeedsYouLive.grouped/1`) with their kept state."
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
  `{:ask, event, reason, text}` (an Ask that did not reach the session) or a
  session-waiting state. A focus or waiting notice replaces the other one.
  """
  def notice(socket, opts, id, notice),
    do: socket |> keep_notice(opts, id, notice) |> reinsert(opts, id)

  @doc "Keeps a card notice (see `notice/4`) without redrawing the card."
  def keep_notice(socket, opts, id, {:ask, event, reason, text}) do
    update(socket, opts[:footers], fn footers ->
      footers |> CardFooter.keep_text(id, text) |> CardFooter.step(id, event, reason)
    end)
  end

  def keep_notice(socket, opts, id, notice) do
    ui =
      case notice do
        {:focus, state} -> %{@ready | focus: state}
        state -> %{@ready | card: state}
      end

    update(socket, opts[:ui], &Map.put(&1, id, ui))
  end

  @doc "After a card action: a sent question clears the text box (`Foreman.CardAsk`)."
  def sent(socket, opts, params, outcome),
    do: socket |> keep_sent(opts, params, outcome) |> reinsert_sent(opts, params, outcome)

  @doc "Like `sent/4`, without redrawing the card."
  def keep_sent(socket, opts, %{"id" => id, "action" => "ask"}, {:ok, _}),
    do: update(socket, opts[:footers], &CardFooter.step(&1, id, :sent))

  def keep_sent(socket, _, _, _), do: socket

  defp reinsert_sent(socket, opts, %{"id" => id, "action" => "ask"}, {:ok, _}),
    do: reinsert(socket, opts, id)

  defp reinsert_sent(socket, _, _, _), do: socket

  @doc """
  The card's input as you type (the text box and the choice). It is kept, not
  redrawn, so your other input stays.
  """
  def text(socket, opts, %{"card_id" => id} = params),
    do: update(socket, opts[:footers], &CardFooter.keep_input(&1, id, params))

  def text(socket, _, _), do: socket

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
