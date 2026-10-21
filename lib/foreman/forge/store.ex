defmodule Foreman.Forge.Store do
  @moduledoc "Transactional forge snapshots and observed overlay events. Missing PRs never imply closure."
  import Ecto.Query
  alias Foreman.{Repo, Overlay}

  def get(key) do
    Repo.one(
      from s in "forge_snapshots",
        where: s.repo_key == ^key,
        select: map(s, [:repo_key, :remote, :snapshot, :state, :error, :synced_at, :attempted_at])
    )
  end

  def replace(key, remote, snapshot) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "foreman:overlay:" <> key
      ])

      old = get(key)

      if old && old.remote != remote do
        Repo.delete_all(from c in "overlay_cr_links", where: c.repo_key == ^key)
      end

      old_prs =
        if old && old.remote == remote, do: old.snapshot["change_requests"] || [], else: []

      ids = Repo.all(from t in "tickets", where: t.repo_key == ^key, select: t.bead_id)
      prefixes = Enum.map(ids, &(String.split(&1, "-", parts: 2) |> hd())) |> Enum.uniq()

      prs =
        Enum.map(snapshot["change_requests"], fn pr ->
          links =
            Enum.flat_map(prefixes, &Foreman.Forge.Stack.links(pr, &1))
            |> Enum.filter(&(&1["bead_id"] in ids))

          Map.put(pr, "links", links)
        end)

      Foreman.Week.PrLinks.record(key, remote, prs)

      # Open all replacements first, so closing one of several links sees its siblings.
      Enum.each(Enum.filter(prs, &(&1["state"] == "open")), fn pr ->
        Enum.each(pr["links"], fn link ->
          id = link["bead_id"]
          row = Overlay.get({key, id})
          previous = Enum.find(old_prs, &(&1["number"] == pr["number"]))

          was_linked =
            previous && previous["state"] == "open" &&
              Enum.any?(previous["links"] || [], &(&1["bead_id"] == id))

          if row && row.machine == Foreman.Stage &&
               (!was_linked ||
                  row.stage in [
                    :queued,
                    :dispatched,
                    :building,
                    :reported,
                    :in_review,
                    :committed
                  ]) do
            Overlay.apply_event({key, id}, {:cr_opened, %{number: pr["number"]}}, %{
              actor: "forge"
            })
          end
        end)
      end)

      Enum.each(prs, fn pr ->
        previous = Enum.find(old_prs, &(&1["number"] == pr["number"]))

        if previous && previous["state"] == "open" do
          Enum.each(previous["links"] || [], fn link ->
            still_linked = Enum.any?(pr["links"], &(&1["bead_id"] == link["bead_id"]))

            if pr["state"] in ["closed", "merged"] || not still_linked do
              event = if pr["state"] == "merged", do: :cr_merged, else: :cr_closed

              Overlay.apply_event({key, link["bead_id"]}, {event, %{number: pr["number"]}}, %{
                actor: "forge"
              })

              # The stage machine may ignore facts on done/abandoned tickets; the open-link
              # guard index must nevertheless reflect the forge's observed reality.
              Repo.delete_all(
                from c in "overlay_cr_links",
                  where:
                    c.repo_key == ^key and c.bead_id == ^link["bead_id"] and
                      c.number == ^pr["number"]
              )
            end
          end)
        end
      end)

      retained =
        Enum.reject(old_prs, fn old_pr -> Enum.any?(prs, &(&1["number"] == old_pr["number"])) end)

      snapshot = Map.put(snapshot, "change_requests", prs ++ retained)
      now = DateTime.utc_now()

      Repo.insert_all(
        "forge_snapshots",
        [
          %{
            repo_key: key,
            remote: remote,
            snapshot: snapshot,
            state: "fresh",
            error: nil,
            synced_at: now,
            attempted_at: now
          }
        ],
        on_conflict: {:replace, [:remote, :snapshot, :state, :error, :synced_at, :attempted_at]},
        conflict_target: [:repo_key]
      )

      Foreman.Events.broadcast(:forge_changed, key)
      :ok
    end)
  end

  def failed(key, remote, reason) do
    now = DateTime.utc_now()

    Repo.insert_all(
      "forge_snapshots",
      [
        %{
          repo_key: key,
          remote: remote,
          snapshot: %{},
          state: "failed",
          error: to_string(reason),
          attempted_at: now
        }
      ],
      on_conflict: {:replace, [:state, :error, :attempted_at]},
      conflict_target: [:repo_key]
    )

    Foreman.Events.broadcast(:forge_changed, key)
  end

  def open_links do
    config = Foreman.RuntimeState.config()
    repos = if config, do: config.config["repos"], else: []

    Repo.all(from s in "forge_snapshots", select: map(s, [:repo_key, :remote, :snapshot]))
    |> Enum.filter(fn row ->
      Enum.any?(
        repos,
        &(&1["key"] == row.repo_key && &1["enabled"] && &1["forge"] == "github" &&
            &1["github"] == row.remote)
      )
    end)
    |> Enum.flat_map(fn row ->
      for pr <- row.snapshot["change_requests"] || [],
          pr["state"] == "open",
          link <- pr["links"] || [],
          do: {{row.repo_key, link["bead_id"]}, {row.repo_key, pr["number"]}}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  def linked({key, id}) do
    case get(key) do
      nil ->
        []

      row ->
        Enum.filter(row.snapshot["change_requests"] || [], fn pr ->
          Enum.any?(pr["links"] || [], &(&1["bead_id"] == id))
        end)
    end
  end
end
