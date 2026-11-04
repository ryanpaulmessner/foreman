defmodule ForemanWeb.CardItems do
  @moduledoc """
  The open cards in the Needs you page stream. A stream
  item cannot be read back, so each card's own state is kept by card id in two
  assigns and every insert builds the full item from them:

  - the card's notices: the session-waiting notice (`Foreman.WaitingCard`) and
    the last Focus terminal result;
  - its footer (`ForemanWeb.CardFooter`): the text box and the Ask state.

  `opts` name the host's assigns: `:ui` and `:footers`.
  """
  import Phoenix.Component, only: [assign: 3, update: 3]
  alias ForemanWeb.CardFooter

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
  def keep_sent(socket, opts, %{"id" => id, "action" => "ask"}, {:ok, _}),
    do: update(socket, opts[:footers], &CardFooter.step(&1, id, :sent))

  def keep_sent(socket, _, _, _), do: socket

  @doc """
  The card's input as you type (the text box and the choice). It is kept, not
  redrawn, so your other input stays.
  """
  def text(socket, opts, %{"card_id" => id} = params),
    do: update(socket, opts[:footers], &CardFooter.keep_input(&1, id, params))

  def text(socket, _, _), do: socket
end
