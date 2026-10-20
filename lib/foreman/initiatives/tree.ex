defmodule Foreman.Initiatives.Tree do
  @moduledoc """
  Pure epic membership over stable `{repo, bead}` keys. Parent-child and explicit
  board links form planned reachability. Discovered-from extends that closure;
  discovery and its descendants win over planned membership. Each ticket counts
  once per epic; sub-epics are containers, not tickets in the denominator.
  Cycles are bounded by visited sets. Unresolved discovery links are not orphans.
  Epics, sub-epics and their tickets sort by their own priority (P0 first), then id;
  top-level epics by priority, then derived stage, then id.
  """
  def build(beads, links \\ []) do
    nodes = Map.new(beads, &{&1.key, &1})

    epics =
      Enum.filter(beads, &(&1.type == "epic")) |> Enum.sort_by(&Foreman.Beads.Id.sort_key(&1.key))

    edges =
      Enum.flat_map(beads, fn b -> Enum.map(b.edges, &{b.key, &1.target, &1.type}) end) ++
        Enum.map(links, &{&1.ticket, &1.epic, "parent-child"})

    all = reverse(edges, ["parent-child", "discovered-from"])
    discovery = reverse(edges, ["discovered-from"])

    memberships =
      Map.new(epics, fn epic ->
        members = closure(MapSet.new([epic.key]), all)
        fallout_seeds = Enum.flat_map(members, &Map.get(discovery, &1, [])) |> MapSet.new()
        fallout = closure(fallout_seeds, all) |> MapSet.delete(epic.key)

        tickets =
          members
          |> Enum.map(&nodes[&1])
          |> Enum.reject(&(is_nil(&1) or &1.type == "epic"))
          |> Enum.sort_by(&{priority_rank(&1), Foreman.Beads.Id.sort_key(&1.key)})

        {epic.key,
         Map.merge(epic, %{
           planned: Enum.reject(tickets, &MapSet.member?(fallout, &1.key)),
           fallout: Enum.filter(tickets, &MapSet.member?(fallout, &1.key)),
           total: length(tickets),
           cr_count: tickets |> Enum.flat_map(&Map.get(&1, :crs, [])) |> Enum.uniq() |> length(),
           closed: Enum.count(tickets, &(&1.status == "closed")),
           histogram: Enum.frequencies_by(tickets, & &1.stage),
           stage: stage(epic.stage, tickets),
           members: members
         })}
      end)

    # Nearest planned epic ancestor gives a sub-epic its single display parent.
    parents = Map.new(epics, fn epic -> {epic.key, parent(epic.key, edges, nodes)} end)
    roots = Enum.reject(epics, &parents[&1.key])
    {trees, visited} = nest(roots, memberships, parents, MapSet.new())
    # Malformed epic cycles still remain visible rather than disappearing.
    remaining = Enum.reject(epics, &MapSet.member?(visited, &1.key))
    {extras, _} = nest(remaining, memberships, parents, visited)

    owned =
      Enum.reduce(memberships, MapSet.new(), fn {_, e}, acc -> MapSet.union(acc, e.members) end)

    linked = MapSet.new(links, & &1.ticket)

    orphans =
      Enum.filter(beads, fn b ->
        b.type != "epic" and not MapSet.member?(owned, b.key) and
          not MapSet.member?(linked, b.key) and
          not Enum.any?(b.edges, &(&1.type == "discovered-from"))
      end)
      |> Enum.sort_by(&Foreman.Beads.Id.sort_key(&1.key))

    %{epics: trees ++ extras, orphans: orphans}
  end

  def stage(tracked, tickets) when tracked in [:ticketed, :done] do
    open = Enum.reject(tickets, &(&1.status == "closed"))

    cond do
      tracked == :done -> :done
      tickets == [] -> :ticketed
      open == [] -> :shipped
      Enum.all?(open, &(&1.stage in [:committed, :pr_open, :merged, :done])) -> :shipping
      Enum.any?(tickets, &(&1.stage not in [:queued, :abandoned])) -> :building
      true -> :ticketed
    end
  end

  def stage(tracked, _), do: tracked

  defp priority_rank(node), do: Foreman.Priority.rank(Map.get(node, :priority))

  defp stage_rank(:building), do: 0
  defp stage_rank(:shipping), do: 1
  defp stage_rank(:ticketed), do: 2
  defp stage_rank(stage) when stage in [:done, :shipped], do: 4
  defp stage_rank(_), do: 3

  defp reverse(edges, types) do
    edges
    |> Enum.filter(fn {_, _, type} -> type in types end)
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
  end

  defp closure(seeds, edges) do
    next =
      Enum.reduce(seeds, seeds, fn key, acc ->
        Enum.reduce(Map.get(edges, key, []), acc, &MapSet.put(&2, &1))
      end)

    if MapSet.equal?(next, seeds), do: seeds, else: closure(next, edges)
  end

  defp parent(key, edges, nodes), do: ancestors([key], edges, nodes, MapSet.new([key]))
  defp ancestors([], _, _, _), do: nil

  defp ancestors(frontier, edges, nodes, seen) do
    next =
      for {from, to, "parent-child"} <- edges,
          from in frontier,
          not MapSet.member?(seen, to),
          do: to

    next = Enum.uniq(next) |> Enum.sort_by(&Foreman.Beads.Id.sort_key/1)

    case Enum.find(next, &(nodes[&1] && nodes[&1].type == "epic")) do
      nil -> ancestors(next, edges, nodes, Enum.reduce(next, seen, &MapSet.put(&2, &1)))
      epic -> epic
    end
  end

  defp nest(epics, memberships, parents, visited) do
    epics
    |> Enum.sort_by(fn epic ->
      {priority_rank(epic), stage_rank(memberships[epic.key].stage),
       Foreman.Beads.Id.sort_key(epic.key)}
    end)
    |> Enum.reduce({[], visited}, fn epic, {acc, visited} ->
      if MapSet.member?(visited, epic.key) do
        {acc, visited}
      else
        children =
          memberships
          |> Map.values()
          |> Enum.filter(&(parents[&1.key] == epic.key))
          |> Enum.sort_by(&{priority_rank(&1), Foreman.Beads.Id.sort_key(&1.key)})

        {children, visited} = nest(children, memberships, parents, MapSet.put(visited, epic.key))
        {acc ++ [Map.put(memberships[epic.key], :children, children)], visited}
      end
    end)
  end
end
