defmodule Foreman.Drilldown do
  @moduledoc "Read models for epic drill-down and ticket detail."
  import Ecto.Query
  alias Foreman.{Repo, Overlay}

  def epic(key) do
    snapshot = Foreman.Initiatives.snapshot(%{"view" => ""})

    lookup =
      case Overlay.get(key) do
        %{machine: Foreman.Epic, beads_epic_id: id} when is_binary(id) -> {elem(key, 0), id}
        _ -> key
      end

    epic = find_epic(snapshot.epics ++ snapshot.drafts, lookup)

    if epic do
      planned = Map.get(epic, :planned, [])
      fallout = Map.get(epic, :fallout, [])
      members = MapSet.new(planned ++ fallout, & &1.key)
      all_beads = beads()

      edges =
        for %{repo_key: repo, bead_id: id, raw: raw} <- all_beads,
            dep <- raw["dependencies"] || [],
            dep["type"] == "blocks",
            from = {repo, dep["depends_on_id"]},
            to = {repo, id},
            MapSet.member?(members, from) or MapSet.member?(members, to),
            do: %{from: from, to: to}

      columns =
        snapshot.columns
        |> Enum.with_index()
        |> Enum.map(fn {col, index} ->
          %{
            id: index,
            title: col["title"],
            stages: col["stages"],
            planned: Enum.filter(planned, &(to_string(&1.stage) in col["stages"])),
            fallout: Enum.filter(fallout, &(to_string(&1.stage) in col["stages"]))
          }
        end)

      Map.merge(epic, %{
        columns: columns,
        planned: planned,
        fallout: fallout,
        total: length(planned ++ fallout),
        closed: Enum.count(planned ++ fallout, &(&1.status == "closed")),
        history: Overlay.history(key),
        edges: Enum.uniq(edges) |> Enum.sort(),
        graph:
          Foreman.BlockingGraph.layout(
            edges,
            planned ++ fallout,
            Map.new(all_beads, &{{&1.repo_key, &1.bead_id}, &1.raw}),
            MapSet.new(fallout, & &1.key)
          ),
        repos: snapshot.repos
      })
    end
  end

  def ticket({repo, id} = key) do
    raw =
      Repo.one(from b in "beads", where: b.repo_key == ^repo and b.bead_id == ^id, select: b.raw)

    overlay = Overlay.get(key)

    if (raw && raw["issue_type"] != "epic") || (overlay && overlay.machine == Foreman.Stage) do
      %{
        key: key,
        repo: repo,
        id: id,
        raw: raw || %{"id" => id},
        stage: if(overlay, do: overlay.stage, else: :queued),
        overlay: overlay,
        dependents:
          for(
            bead <- beads(),
            bead.repo_key == repo,
            dep <- bead.raw["dependencies"] || [],
            dep["depends_on_id"] == id,
            do: %{key: {repo, bead.bead_id}, type: dep["type"]}
          ),
        attachments:
          Repo.all(
            from l in "epic_links",
              where: l.repo_key == ^repo and l.bead_id == ^id,
              order_by: [l.epic_repo_key, l.epic_bead_id],
              select: %{repo: l.epic_repo_key, id: l.epic_bead_id}
          ),
        history: ticket_history(key),
        allowed: Overlay.allowed_events(key),
        sessions:
          Repo.all(
            from s in "sessions",
              where: s.repo_key == ^repo and s.bead_id == ^id,
              order_by: [desc: s.id],
              select: map(s, [:id, :window, :details, :started_at, :last_seen_at, :ended_at])
          ),
        notes:
          Repo.all(
            from n in "agent_notes",
              where: n.repo_key == ^repo and n.bead_id == ^id,
              order_by: [desc: n.id],
              select: map(n, [:id, :actor, :kind, :body, :inserted_at])
          ),
        crs:
          Repo.all(
            from c in "overlay_cr_links",
              where: c.repo_key == ^repo and c.bead_id == ^id,
              order_by: c.number,
              select: c.number
          ),
        change_requests: Foreman.Forge.Store.linked(key),
        close_suggested:
          overlay && overlay.stage == :merged &&
            Enum.any?(Overlay.history(key), fn event ->
              Enum.any?(
                event.effects || [],
                &(&1 == %{"kind" => "suggest", "name" => "close_bead"})
              )
            end)
      }
    end
  end

  defp ticket_history(key) do
    notes =
      for note <- Foreman.CloseOutNags.history(key) do
        %{
          id: "note-#{note.id}",
          event: "note_to_coordinator",
          source: "board",
          actor: "board",
          from_stage: nil,
          to_stage: nil,
          outcome: note.result,
          payload: %{"owner" => note.owner, "reason" => note.reason, "body" => note.text},
          effects: [],
          inserted_at: note.inserted_at
        }
      end

    (Overlay.history(key) ++ notes)
    |> Enum.with_index()
    |> Enum.sort_by(fn {event, index} -> {sort_time(event.inserted_at), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp sort_time(%DateTime{} = time), do: DateTime.to_unix(time, :microsecond)

  defp sort_time(%NaiveDateTime{} = time),
    do: time |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)

  defp sort_time(_), do: 0

  defp find_epic(epics, key) do
    Enum.find_value(epics, fn epic ->
      if epic.key == key, do: epic, else: find_epic(Map.get(epic, :children, []), key)
    end)
  end

  defp beads, do: Repo.all(from b in "beads", select: map(b, [:repo_key, :bead_id, :raw]))
end
