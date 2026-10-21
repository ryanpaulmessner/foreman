defmodule Foreman.Initiatives do
  @moduledoc "Snapshot query for the initiatives home. Filters never alter rolled-up totals."
  import Ecto.Query
  alias Foreman.{Repo, RuntimeState}
  alias Foreman.Initiatives.Tree

  def snapshot(filters \\ %{}) do
    config =
      case RuntimeState.config() do
        nil -> %{"repos" => [], "columns" => [], "board" => %{}}
        row -> row.config
      end

    views = Foreman.Config.views(config)
    filters = Foreman.Initiatives.Filters.effective(filters, views)
    repos = RuntimeState.repos()
    keys = Enum.map(repos, & &1["key"])

    tickets =
      Repo.all(from t in "tickets", select: %{key: {t.repo_key, t.bead_id}, stage: t.stage})
      |> Map.new(&{&1.key, &1.stage})

    epics =
      Repo.all(
        from e in "epics",
          select: %{
            repo_key: e.repo_key,
            bead_id: e.bead_id,
            beads_epic_id: e.beads_epic_id,
            stage: e.stage,
            title: e.title,
            spec_link: e.spec_link
          }
      )

    epic_map = Map.new(epics, &{{&1.repo_key, &1.beads_epic_id || &1.bead_id}, &1})

    planning_sessions =
      Repo.all(Foreman.PlanningSession) |> Map.new(&{{&1.project, &1.ticket}, &1})

    sessions =
      Repo.all(
        from s in "sessions",
          where: is_nil(s.ended_at),
          order_by: s.id,
          select: %{key: {s.repo_key, s.bead_id}, last_seen_at: s.last_seen_at}
      )
      |> Map.new(&{&1.key, &1.last_seen_at})

    threshold = stale_seconds(config["board"]["stale_session_after"] || "2h")

    cr_links = Foreman.Forge.Store.open_links()
    priority_overrides = Foreman.Priority.override_map(keys)

    beads =
      Repo.all(
        from b in "beads", where: b.repo_key in ^keys, select: %{repo: b.repo_key, raw: b.raw}
      )
      |> Enum.map(fn %{repo: repo, raw: raw} ->
        key = {repo, raw["id"]}
        epic = epic_map[key]

        stage =
          if epic,
            do: stage_atom(epic.stage),
            else:
              stage_atom(
                tickets[key] || if(raw["status"] == "closed", do: "done", else: "queued")
              )

        override = priority_overrides[key]

        %{
          key: key,
          crs: Map.get(cr_links, key, []),
          priority: override || raw["priority"],
          priority_changed: not is_nil(override),
          repo: repo,
          id: raw["id"],
          title: raw["title"],
          type: raw["issue_type"],
          kind: raw["kind"],
          status: raw["status"],
          created_at: created_at(raw["created_at"] || raw["created"]),
          parked_at: created_at(raw["parked"]),
          parked_reason: raw["parked_reason"],
          labels: raw["labels"] || [],
          stage: stage,
          spec_link: epic && epic.spec_link,
          planning_session: planning_sessions[key],
          stale: stale?(raw, stage, sessions[key], threshold),
          edges:
            Enum.map(
              raw["dependencies"] || [],
              &%{target: {repo, &1["depends_on_id"]}, type: &1["type"]}
            )
        }
      end)

    epic_aliases =
      Map.new(epics, &{{&1.repo_key, &1.bead_id}, {&1.repo_key, &1.beads_epic_id || &1.bead_id}})

    links =
      Repo.all(
        from l in "epic_links",
          select: %{ticket: {l.repo_key, l.bead_id}, epic: {l.epic_repo_key, l.epic_bead_id}}
      )
      |> Enum.map(fn link -> %{link | epic: Map.get(epic_aliases, link.epic, link.epic)} end)

    beads = Foreman.Initiatives.Kinds.resolve(beads, config["repos"], links)
    tree = Tree.build(beads, links)

    drafts =
      epics
      |> Enum.filter(&(is_nil(&1.beads_epic_id) and &1.repo_key in keys))
      |> Enum.map(fn e ->
        %{
          key: {e.repo_key, e.bead_id},
          repo: e.repo_key,
          id: e.bead_id,
          title: e.title,
          type: "epic",
          status: if(e.stage == "done", do: "closed", else: "open"),
          stage: stage_atom(e.stage),
          labels: [],
          stale: false,
          spec_link: e.spec_link,
          planning_session: planning_sessions[{e.repo_key, e.bead_id}]
        }
      end)
      |> Enum.filter(&matches?(&1, Map.delete(filters, "kind")))
      |> Enum.sort_by(&Foreman.Beads.Id.sort_key(&1.key))

    parentless =
      tree.orphans
      |> Enum.reject(&(&1.status in ["closed", "parked"]))
      |> Enum.sort_by(fn ticket ->
        age =
          case ticket.created_at do
            nil -> {1, 0}
            time -> {0, -DateTime.to_unix(time, :microsecond)}
          end

        {Foreman.Priority.rank(ticket.priority), age}
      end)

    %{
      drafts: drafts,
      sections: kind_sections(tree, beads, filters),
      swimlanes: config["board"]["swimlanes"],
      parked:
        beads
        |> Enum.filter(&(&1.status == "parked" and matches?(&1, filters)))
        |> Enum.map(&Map.put(&1, :parked_epics, parked_epics(tree.epics, &1.key)))
        |> Enum.sort_by(
          &{is_nil(&1.parked_at), &1.parked_at && DateTime.to_unix(&1.parked_at), &1.key}
        ),
      epics: Enum.filter(tree.epics, &epic_matches?(&1, filters)),
      orphans:
        parentless
        |> Enum.reject(&standalone?/1)
        |> Enum.filter(&matches?(&1, filters)),
      standalone:
        parentless
        |> Enum.filter(&standalone?/1)
        |> Enum.filter(&matches?(&1, filters_for_standalone_in_flight(filters))),
      repos: repos,
      columns: config["columns"],
      views: views,
      filters: filters,
      types: beads |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.sort(),
      labels: beads |> Enum.flat_map(& &1.labels) |> Enum.uniq() |> Enum.sort()
    }
  end

  defp kind_sections(tree, beads, filters) do
    {active, _} = tree.epics |> open_epics() |> display_ownership(MapSet.new())

    owned = Enum.reduce(active, MapSet.new(), &MapSet.union(&1.members, &2))

    loose =
      beads
      |> Enum.reject(
        &(&1.type == "epic" or &1.status in ["closed", "parked"] or MapSet.member?(owned, &1.key))
      )
      |> Enum.sort_by(fn b ->
        {Foreman.Priority.rank(b.priority), is_nil(b.created_at),
         b.created_at && -DateTime.to_unix(b.created_at, :microsecond),
         Foreman.Beads.Id.sort_key(b.key)}
      end)
      |> Enum.filter(fn b ->
        matches?(
          b,
          if(standalone?(b), do: filters_for_standalone_in_flight(filters), else: filters)
        )
      end)

    active = Enum.filter(active, &epic_matches?(&1, filters))
    # Preserve trees when a child's explicit kind differs from its display root.
    for {kind, label} <- Foreman.Initiatives.Kinds.options(),
        epics = Enum.filter(active, &(&1.effective_kind == kind)),
        tickets = Enum.filter(loose, &(&1.effective_kind == kind)),
        epics != [] or tickets != [] do
      keys =
        Enum.reduce(epics, MapSet.new(Enum.map(tickets, & &1.key)), &MapSet.union(&1.members, &2))

      count =
        Enum.count(
          beads,
          &(MapSet.member?(keys, &1.key) and &1.status not in ["closed", "parked"])
        )

      %{
        kind: kind,
        label: label,
        epics: epics,
        in_flight: Enum.filter(tickets, &standalone?/1),
        never_started: Enum.reject(tickets, &standalone?/1),
        count: count
      }
    end
  end

  # Display ownership is single-valued even when imported edges link a ticket
  # to multiple roots. Tree.build retains the full rollups for progress and Done.
  defp display_ownership(epics, seen) do
    Enum.map_reduce(epics, seen, fn epic, seen ->
      {children, seen} = display_ownership(epic.children, seen)
      nested = Enum.reduce(children, MapSet.new(), &MapSet.union(&1.members, &2))

      taken? = fn b ->
        b.status == "closed" or
          (MapSet.member?(seen, b.key) and not MapSet.member?(nested, b.key))
      end

      planned = Enum.reject(epic.planned, taken?)
      seen = Enum.reduce(planned, seen, &MapSet.put(&2, &1.key))
      fallout = Enum.reject(epic.fallout, taken?)
      seen = Enum.reduce(fallout, seen, &MapSet.put(&2, &1.key)) |> MapSet.put(epic.key)
      members = MapSet.new([epic.key | Enum.map(planned ++ fallout, & &1.key)])
      members = Enum.reduce(children, members, &MapSet.union(&1.members, &2))
      display = %{epic | planned: planned, fallout: fallout, children: children, members: members}
      {Map.put(display, :fallout_count, length(epic.fallout)), seen}
    end)
  end

  defp open_epics(epics) do
    Enum.flat_map(epics, fn epic ->
      children = open_epics(epic.children)

      if epic.status == "closed" or epic.stage in [:done, :shipped],
        do: children,
        else: [%{epic | children: children}]
    end)
  end

  defp parked_epics(epics, key) do
    Enum.flat_map(epics, fn epic ->
      children = parked_epics(epic.children, key)

      cond do
        children != [] -> children
        MapSet.member?(epic.members, key) and epic.key != key -> [Map.take(epic, [:id, :title])]
        true -> []
      end
    end)
  end

  defp filters_for_standalone_in_flight(%{"view" => "in-flight"} = filters),
    do: Map.put(filters, "stages", [])

  defp filters_for_standalone_in_flight(filters), do: filters

  # Unplanned = never started (queued, not claimed). Anything else that is not
  # closed (in flight, or finished but still open) is Standalone work, so no
  # open ticket disappears from both lists.
  defp standalone?(ticket), do: ticket.status == "in_progress" or ticket.stage != :queued

  def matches?(b, filters) do
    Enum.all?(filters, fn
      {"project", value} ->
        value in ["", "all"] or b.repo == value

      {"kind", value} ->
        value in [nil, "", "all"] or Map.get(b, :effective_kind, "unsorted") == value

      {"type", value} ->
        value in ["", "all"] or b.type == value

      {"label", value} ->
        value == "" or value in b.labels

      {"status", value} ->
        value in ["", "all"] or (value == "open" and b.status != "closed") or b.status == value

      {"statuses", values} ->
        values == [] or b.status in values

      {"stages", values} ->
        values == [] or (b.type != "epic" and to_string(b.stage) in values)

      {"stale", value} ->
        value != "true" or b.stale

      {"q", value} ->
        String.contains?(
          String.downcase(b.id <> " " <> (b.title || "") <> " " <> Enum.join(b.labels, " ")),
          String.downcase(value)
        )

      _ ->
        true
    end)
  end

  defp epic_matches?(epic, filters),
    do:
      matches?(%{epic | stale: Enum.any?(epic.planned ++ epic.fallout, & &1.stale)}, filters) or
        Enum.any?(epic.planned ++ epic.fallout, &matches?(&1, filters)) or
        Enum.any?(epic.children, &epic_matches?(&1, filters))

  defp created_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} ->
        time

      _ ->
        case Date.from_iso8601(value) do
          {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
          _ -> nil
        end
    end
  end

  defp created_at(_), do: nil

  defp stage_atom(value),
    do:
      Enum.find(
        Foreman.Stage.__fsm__(:states) ++ Foreman.Epic.__fsm__(:states),
        &(to_string(&1) == value)
      )

  defp stale_seconds(value) do
    case Regex.run(~r/^(\d+)(s|m|h|d)$/, value) do
      [_, n, unit] ->
        String.to_integer(n) * %{"s" => 1, "m" => 60, "h" => 3600, "d" => 86400}[unit]

      _ ->
        7200
    end
  end

  defp stale?(raw, stage, last, threshold) do
    active = stage in [:dispatched, :building] or raw["status"] == "in_progress"

    raw["status"] != "parked" and active and
      (is_nil(last) or NaiveDateTime.diff(NaiveDateTime.utc_now(), last) > threshold)
  end
end
