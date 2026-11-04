defmodule ForemanWeb.CardFooter do
  @moduledoc """
  The footer state of each card on a page, kept on the server by card id: the
  text in the card's one text box, and its `Foreman.CardAsk` state with the
  reason of a failed send. Needs you and the request drawer each keep a map of
  these in one assign.
  """
  alias Foreman.CardAsk

  @empty %{ask: :idle, reason: nil, text: ""}

  @doc "A card's footer; a card with none yet has no text and nothing to show."
  def get(footers, id), do: Map.get(footers, id, @empty)

  @doc """
  Fires `event` on the card's Ask machine. `reason` is kept for the `failed`
  line. Returns the new footers.
  """
  def step(footers, id, event, reason \\ nil) do
    footer = get(footers, id)
    {ask, effects} = CardAsk.step(footer.ask, event, %{})
    text = if Keyword.has_key?(effects, :clear_text), do: "", else: footer.text
    Map.put(footers, id, %{ask: ask, reason: reason, text: text})
  end

  @doc "Keeps the text typed in the card's text box."
  def keep_text(footers, id, text) when is_binary(text),
    do: Map.update(footers, id, %{@empty | text: text}, &%{&1 | text: text})

  @forms ~w(decision batch chore waiting)

  @doc """
  The text box in card form params. Each kind's form names it `<form>[note]`;
  Try again on a failed Ask sends it as `text`.
  """
  def text(params), do: Enum.find_value(@forms, params["text"], &get_in(params, [&1, "note"]))

  @doc "Drops the footers of cards that are no longer on the page."
  def prune(footers, ids), do: Map.filter(footers, fn {id, _} -> MapSet.member?(ids, id) end)
end
