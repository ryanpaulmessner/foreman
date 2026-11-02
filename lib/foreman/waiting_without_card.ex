defmodule Foreman.WaitingWithoutCard do
  @moduledoc "Read-only work that needs a human but has no pending request. No git or network calls."
  import Ecto.Query
  alias Foreman.{Repo, Requests.Request}

  def list do
    stored = Foreman.RuntimeState.config()
    config = if stored, do: stored.config, else: %{}
    repos = Enum.filter(config["repos"] || [], & &1["enabled"])
    keys = Enum.map(repos, & &1["key"])

    tickets =
      Repo.all(
        from t in "tickets",
          join: b in "beads",
          on: b.repo_key == t.repo_key and b.bead_id == t.bead_id,
          where: t.repo_key in ^keys and is_nil(t.orphaned_at),
          select: %{repo_key: t.repo_key, bead_id: t.bead_id, stage: t.stage, raw: b.raw}
      )

    ticket_keys = MapSet.new(tickets, &key/1)

    live =
      Enum.filter(
        tickets,
        &(&1.stage not in ["done", "abandoned"] and &1.raw["status"] != "closed")
      )

    requests =
      Repo.all(
        from r in Request,
          where:
            r.repo_key in ^keys and
              (r.state == "pending" or
                 (r.kind == "push" and r.state in ["approved", "executing", "done"]))
      )

    pending = MapSet.new(for r <- requests, r.state == "pending", do: {r.repo_key, r.bead_id})
    pushed = MapSet.new(for r <- requests, r.kind == "push", do: {r.repo_key, r.bead_id})

    stage_items =
      for t <- live,
          not MapSet.member?(pending, key(t)),
          t.stage == "reported" or
            (t.stage == "committed" and not MapSet.member?(pushed, key(t)) and
               push_repo?(repos, t.repo_key)) do
        if t.stage == "reported",
          do: item(t, "report", "Review the report", ticket_path(t)),
          else: item(t, "push", "Request a push", ticket_path(t))
      end

    blocked =
      for(
        t <- live,
        edge <- t.raw["dependencies"] || [],
        edge["type"] == "blocks",
        do: {{t.repo_key, edge["depends_on_id"]}, t.bead_id}
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    decisions =
      for t <- live,
          t.raw["issue_type"] == "decision",
          Map.has_key?(blocked, key(t)),
          not MapSet.member?(pending, key(t)) do
        ids = blocked[key(t)] |> Enum.uniq() |> Enum.sort_by(&Foreman.Beads.Id.sort_key/1)

        item(t, "decision", "Answer the decision", ticket_path(t))
        |> Map.put(:detail, "Blocks " <> Enum.join(ids, ", "))
      end

    merges =
      for repo <- repos,
          Foreman.MergePolicy.human?(repo, config),
          repo["forge"] == "github",
          snapshot = Foreman.Forge.Store.get(repo["key"]),
          snapshot && snapshot.remote == repo["github"],
          pr <- snapshot.snapshot["change_requests"] || [],
          pr["state"] == "open",
          Enum.any?(pr["links"] || [], fn link ->
            MapSet.member?(ticket_keys, {repo["key"], link["bead_id"]})
          end),
          not covered_pr?(requests, repo["key"], pr) do
        %{
          id: "merge:#{repo["key"]}:#{pr["number"]}",
          kind: "merge",
          repo_key: repo["key"],
          bead_id: nil,
          detail: nil,
          title: "PR ##{pr["number"]}: #{pr["title"]}",
          action: "Review and merge on GitHub",
          href: pr["url"] || "/pull-requests?" <> URI.encode_query(%{"project" => repo["key"]})
        }
      end

    (stage_items ++ decisions ++ merges)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&{&1.repo_key, &1.kind, &1.id})
  end

  defp key(t), do: {t.repo_key, t.bead_id}
  defp push_repo?(repos, key), do: Enum.any?(repos, &(&1["key"] == key and &1["forge"] != "none"))

  defp ticket_path(t),
    do: "/needs-you?" <> URI.encode_query(%{"ticket" => t.repo_key <> ":" <> t.bead_id})

  defp item(t, kind, action, href),
    do: %{
      id: "#{kind}:#{t.repo_key}:#{t.bead_id}",
      kind: kind,
      repo_key: t.repo_key,
      bead_id: t.bead_id,
      detail: nil,
      title: t.raw["title"] || t.bead_id,
      action: action,
      href: href
    }

  defp covered_pr?(requests, repo, pr) do
    linked = Enum.map(pr["links"] || [], & &1["bead_id"])

    Enum.any?(requests, fn r ->
      r.repo_key == repo and r.state == "pending" and
        (r.bead_id in linked or r.facts["number"] == pr["number"])
    end)
  end
end
