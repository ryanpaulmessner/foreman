defmodule ForemanWeb.CardFooter do
  @moduledoc """
  The footer state of each card on a page: its `Foreman.CardFooterPanel` state and
  the text typed in its panels, kept on the server by card id. Needs you and the
  request drawer each keep a map of these in one assign.
  """
  alias Foreman.CardFooterPanel

  @empty %{panel: :none, text: %{}}

  @doc "A card's footer; a card with none yet has no panel open and no text."
  def get(footers, id), do: Map.get(footers, id, @empty)

  @doc """
  Fires `event` on the card's panel machine. Returns the new footers and the
  machine's effects, or `:error` for an event the machine refuses.
  """
  def step(footers, id, event) do
    footer = get(footers, id)

    case CardFooterPanel.step(footer.panel, event, %{}) do
      {:error, _} ->
        :error

      {panel, effects} ->
        text =
          Enum.reduce(effects, footer.text, fn
            {:clear_text, which}, text -> Map.delete(text, which)
            _, text -> text
          end)

        {Map.put(footers, id, %{panel: panel, text: text}), effects}
    end
  end

  @doc "Keeps the text typed in one of the card's panels."
  def keep_text(footers, id, panel, text) when is_binary(text) do
    footer = get(footers, id)
    Map.put(footers, id, %{footer | text: Map.put(footer.text, panel, text)})
  end

  @doc "Drops the footers of cards that are no longer on the page."
  def prune(footers, ids), do: Map.filter(footers, fn {id, _} -> MapSet.member?(ids, id) end)
end
