defmodule Foreman.Week do
  @moduledoc "Read-only local facts for the weekly page. No git or network calls."
  import Ecto.Query
  alias Foreman.{Repo, RuntimeState}
  alias Foreman.Week.Model

  def snapshot(now \\ DateTime.utc_now()) do
    stored = RuntimeState.config()
    config = if stored, do: stored.config, else: %{}
    board = config["board"] || %{}
    timezone = board["timezone"] || "America/Chicago"
    keys = board["week_repos"] || ["work"]
    window = Model.window(now, timezone)
    repos = config["repos"] || []

    stages =
      Repo.all(
        from t in "tickets",
          where: t.repo_key in ^keys,
          select: {{t.repo_key, t.bead_id}, t.stage}
      )
      |> Map.new()

    epics =
      Repo.all(
        from e in "epics",
          select: %{repo: e.repo_key, id: e.bead_id, ticket_id: e.beads_epic_id, stage: e.stage}
      )

    aliases = Map.new(epics, &{{&1.repo, &1.id}, {&1.repo, &1.ticket_id || &1.id}})
    stages = Enum.reduce(epics, stages, &Map.put(&2, {&1.repo, &1.ticket_id || &1.id}, &1.stage))

    links =
      Repo.all(
        from l in "epic_links",
          select: %{ticket: {l.repo_key, l.bead_id}, epic: {l.epic_repo_key, l.epic_bead_id}}
      )
      |> Enum.map(&%{&1 | epic: Map.get(aliases, &1.epic, &1.epic)})

    prs =
      Repo.all(
        from s in "forge_snapshots",
          where: s.repo_key in ^keys,
          select: %{repo: s.repo_key, remote: s.remote, snapshot: s.snapshot}
      )
      |> Enum.filter(fn s ->
        Enum.any?(
          repos,
          &(&1["key"] == s.repo and &1["github"] == s.remote and &1["forge"] == "github")
        )
      end)
      |> Enum.flat_map(fn s ->
        for pr <- s.snapshot["change_requests"] || [],
            link <- pr["links"] || [],
            do: {{s.repo, link["bead_id"]}, pr}
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    tickets =
      Repo.all(from b in "beads", select: %{repo: b.repo_key, raw: b.raw})
      |> Enum.map(fn %{repo: repo, raw: raw} ->
        key = {repo, raw["id"]}

        %{
          key: key,
          repo: repo,
          id: raw["id"],
          title: raw["title"],
          type: raw["issue_type"],
          kind: raw["kind"],
          status: raw["status"],
          stage: Map.get(stages, key, if(raw["status"] == "closed", do: "done", else: "queued")),
          raw: raw,
          prs: Map.get(prs, key, []),
          edges:
            Enum.map(
              raw["dependencies"] || [],
              &%{target: {repo, &1["depends_on_id"]}, type: &1["type"]}
            )
        }
      end)

    events =
      Repo.all(
        from e in "stage_events",
          where:
            e.repo_key in ^keys and e.inserted_at >= ^window.start_at and
              e.inserted_at < ^window.end_at,
          select: %{
            key: {e.repo_key, e.bead_id},
            inserted_at: type(e.inserted_at, :utc_datetime_usec)
          }
      )

    request_events =
      Repo.all(
        from e in "request_events",
          join: r in "approval_requests",
          on: r.id == e.request_id,
          where:
            r.repo_key in ^keys and e.inserted_at >= ^window.start_at and
              e.inserted_at < ^window.end_at,
          select: %{
            key: {r.repo_key, r.bead_id},
            inserted_at: type(e.inserted_at, :utc_datetime_usec)
          }
      )

    requests =
      Repo.all(
        from r in "approval_requests",
          where:
            r.repo_key in ^keys and
              (r.state == "pending" or
                 (r.inserted_at >= ^window.start_at and r.inserted_at < ^window.end_at)),
          select: %{
            key: {r.repo_key, r.bead_id},
            id: type(r.id, :string),
            kind: r.kind,
            state: r.state,
            inserted_at: type(r.inserted_at, :utc_datetime_usec)
          }
      )

    canonical = fn row -> %{row | key: Map.get(aliases, row.key, row.key)} end

    Model.build(
      %{
        tickets: tickets,
        events: Enum.map(events ++ request_events, canonical),
        requests: Enum.map(requests, canonical),
        repos: repos,
        links: links,
        pr_containment: [],
        sent_reports: []
      },
      now,
      timezone: timezone,
      week_repos: keys
    )
  end
end
