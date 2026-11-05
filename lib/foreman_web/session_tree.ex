defmodule ForemanWeb.SessionTree do
  @moduledoc "Outline and waiting-strip projection of session identities. No terminal reads."
  alias ForemanWeb.SessionState

  def build(entries, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    entries = Enum.map(entries, &Map.put(&1, :view, SessionState.view(&1.facts, now)))

    waiting =
      entries
      |> Enum.filter(&(&1.view.label == "Waiting on you"))
      |> Enum.sort_by(& &1.row.name)
      |> Enum.map(&waiting/1)

    recent? = fn e -> e.row.ended_at && DateTime.diff(now, e.row.ended_at) <= 7 * 86400 end
    ended_count = Enum.count(entries, recent?)

    visible =
      Enum.filter(
        entries,
        &(is_nil(&1.row.ended_at) or &1.view.label == "Waiting on you" or
            (Keyword.get(opts, :show_ended, false) and recent?.(&1)))
      )

    kept = retain_parents(MapSet.new(visible, & &1.row.id), entries)
    entries = Enum.filter(entries, &MapSet.member?(kept, &1.row.id))
    roots = Enum.filter(entries, &(&1.row.kind == "main_coordinator"))
    ids = MapSet.new(entries, & &1.row.id)

    orphans =
      Enum.filter(
        entries,
        &(&1.row.kind != "main_coordinator" and not MapSet.member?(ids, &1.row.parent_id))
      )

    rows = outline(roots, entries, 0, [])

    rows =
      if orphans == [],
        do: rows,
        else:
          rows ++ [%{id: "unassigned", depth: 0, group: true}] ++ outline(orphans, entries, 1, [])

    %{rows: rows, waiting: waiting, ended_count: ended_count}
  end

  defp retain_parents(ids, entries) do
    next =
      Enum.reduce(entries, ids, fn e, acc ->
        if MapSet.member?(ids, e.row.id) and e.row.parent_id,
          do: MapSet.put(acc, e.row.parent_id),
          else: acc
      end)

    if next == ids, do: ids, else: retain_parents(next, entries)
  end

  defp waiting(entry) do
    cards = entry.facts.open_cards

    terminal_wait? =
      is_nil(entry.row.ended_at) and
        entry.facts.state in ["waiting.permission", "waiting.usage_limit"]

    action =
      cond do
        cards > 0 and not terminal_wait? ->
          "Answer #{cards} #{if cards == 1, do: "card", else: "cards"}" <>
            if(entry.row.ended_at, do: " · session ended", else: "")

        entry.facts.state == "waiting.permission" ->
          "Permission prompt · open the terminal"

        entry.facts.state == "waiting.usage_limit" ->
          "Usage limit · press Continue"

        true ->
          "Answer on the card"
      end

    href =
      case entry.cards do
        [card | _] when cards > 0 and not terminal_wait? -> "/needs-you?card=#{card.id}"
        _ -> "/sessions/#{entry.row.id}"
      end

    Map.merge(entry, %{id: entry.row.id, action: action, href: href})
  end

  defp outline(roots, entries, depth, ancestors) do
    roots
    |> Enum.sort_by(& &1.row.name)
    |> Enum.flat_map(fn entry ->
      id = entry.row.id

      children =
        Enum.filter(entries, &(&1.row.parent_id == id and &1.row.id not in [id | ancestors]))

      item = Map.merge(entry, %{id: id, depth: depth, ancestors: ancestors, group: false})
      [item | outline(children, entries, depth + 1, [id | ancestors])]
    end)
  end
end
