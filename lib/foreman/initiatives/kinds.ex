defmodule Foreman.Initiatives.Kinds do
  @moduledoc "Ticket kind resolution over repository-scoped parent edges."

  def options,
    do:
      Enum.zip(Foreman.TicketFile.kinds() ++ ["unsorted"], [
        "Break-fix",
        "Mapping",
        "Access",
        "Feature",
        "Internal",
        "Unsorted"
      ])

  def resolve(beads, repos, links \\ []) do
    nodes = Map.new(beads, &{&1.key, &1})
    defaults = Map.new(repos, &{&1["key"], &1["default_kind"]})

    parents =
      (Enum.flat_map(beads, fn b ->
         for edge <- b.edges,
             edge.type in ["parent-child", "discovered-from"],
             do: {b.key, edge.target}
       end) ++ Enum.map(links, &{&1.ticket, &1.epic}))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Enum.map(beads, fn b ->
      kind =
        valid(Map.get(b, :kind)) ||
          ancestor(Map.get(parents, b.key, []), nodes, parents, MapSet.new([b.key])) ||
          valid(defaults[b.repo]) || "unsorted"

      Map.put(b, :effective_kind, kind)
    end)
  end

  defp valid(kind), do: if(kind in Foreman.TicketFile.kinds(), do: kind)
  defp ancestor([], _, _, _), do: nil

  defp ancestor(frontier, nodes, parents, seen) do
    frontier = frontier |> Enum.reject(&MapSet.member?(seen, &1)) |> Enum.uniq() |> Enum.sort()
    epic = Enum.find(frontier, &(nodes[&1] && nodes[&1].type == "epic"))

    if epic do
      valid(Map.get(nodes[epic], :kind)) ||
        ancestor(Map.get(parents, epic, []), nodes, parents, MapSet.put(seen, epic))
    else
      next = Enum.flat_map(frontier, &Map.get(parents, &1, []))
      ancestor(next, nodes, parents, Enum.reduce(frontier, seen, &MapSet.put(&2, &1)))
    end
  end
end
