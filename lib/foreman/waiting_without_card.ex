defmodule Foreman.WaitingWithoutCard do
  @moduledoc """
  Work that waits on someone but has no pending card. Read-only; no git or network calls.

  `list/0` is the work a person does: open pull requests in human-merge GitHub repos.
  `stuck/0` is agent close-out work (a report not reviewed, a commit with no push card,
  a decision ticket with no card). It never shows on Needs you; `Foreman.CloseOutNags`
  sends the owning coordinator a note instead.

  A pull request belongs to a ticket when the PR links the ticket or its head branch is a
  branch recorded for the ticket (dispatch, push or PR cards). Parked tickets are never
  listed. A ticket whose pull request is open or merged is not stuck.
  """
  import Ecto.Query
  alias Foreman.{Repo, Requests.Request}

  @parked ~w(parked deferred)

  @doc "Open pull requests for a person to merge, oldest first."
  def list do
    state = state(:merge_cards)

    rows =
      for repo <- state.repos,
          Foreman.MergePolicy.human?(repo, state.config),
          repo["forge"] == "github",
          pr <- prs(state, repo["key"]),
          pr["state"] == "open",
          is_binary(pr["url"]),
          tickets = pr_tickets(state, repo["key"], pr),
          tickets != [],
          not Enum.all?(tickets, &parked?/1),
          not covered_pr?(state.requests, repo["key"], pr, tickets) do
        %{
          id: "merge:#{repo["key"]}:#{pr["number"]}",
          repo_key: repo["key"],
          number: pr["number"],
          title: pr["title"],
          url: pr["url"],
          bead_ids:
            tickets |> Enum.map(& &1.bead_id) |> Enum.sort_by(&Foreman.Beads.Id.sort_key/1),
          opened_at: time(pr["created_at"])
        }
      end

    Enum.sort_by(
      rows,
      &{&1.opened_at == nil, &1.opened_at && DateTime.to_unix(&1.opened_at, :microsecond),
       &1.repo_key, &1.number}
    )
  end

  @doc """
  Agent close-out work with no pending card. `since` is when the item last changed
  (stage or cards); `fingerprint` changes whenever the stage or the ticket's cards change.
  """
  def stuck do
    state = state(:all_cards)
    live = Enum.filter(state.tickets, &(live?(&1) and not parked?(&1)))

    stage_items =
      for t <- live,
          not pending?(state, t),
          not past_close_out?(state, t),
          kind = stage_kind(state, t),
          kind != nil,
          do: stuck_item(state, t, kind, nil)

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
          not pending?(state, t) do
        ids = blocked[key(t)] |> Enum.uniq() |> Enum.sort_by(&Foreman.Beads.Id.sort_key/1)
        stuck_item(state, t, "decision", ids)
      end

    (stage_items ++ decisions)
    |> Enum.uniq_by(&{&1.repo_key, &1.bead_id})
    |> Enum.sort_by(&{&1.repo_key, Foreman.Beads.Id.sort_key(&1.bead_id)})
  end

  defp state(scope) do
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
          select: %{
            repo_key: t.repo_key,
            bead_id: t.bead_id,
            stage: t.stage,
            stage_changed_at: t.stage_changed_at,
            raw: b.raw
          }
      )

    requests =
      Repo.all(
        from r in Request,
          where:
            r.repo_key in ^keys and
              (^(scope == :all_cards) or r.state == "pending" or r.kind in ["push", "open_pr"]),
          order_by: [asc: r.updated_at]
      )

    dispatch_branches =
      Repo.all(
        from e in "stage_events",
          where: e.repo_key in ^keys and e.event == "dispatch" and e.outcome == "row",
          select: {e.repo_key, e.bead_id, fragment("?->>'branch'", e.payload)}
      )

    request_branches =
      for r <- requests,
          r.kind in ["push", "open_pr"],
          branch <- [r.facts["remote_branch"], r.facts["local_branch"], r.facts["head_branch"]],
          do: {r.repo_key, r.bead_id, branch}

    branches =
      (dispatch_branches ++ request_branches)
      |> Enum.filter(fn {_, _, branch} -> is_binary(branch) and branch != "" end)
      |> Enum.group_by(fn {repo, _, branch} -> {repo, branch} end, fn {_, id, _} -> id end)

    %{
      config: config,
      repos: repos,
      tickets: tickets,
      by_key: Map.new(tickets, &{key(&1), &1}),
      requests: requests,
      by_ticket: Enum.group_by(requests, &{&1.repo_key, &1.bead_id}),
      branches: branches,
      snapshots:
        Map.new(repos, fn repo ->
          snapshot = Foreman.Forge.Store.get(repo["key"])

          prs =
            if snapshot && snapshot.remote == repo["github"],
              do: snapshot.snapshot["change_requests"] || [],
              else: []

          {repo["key"], prs}
        end)
    }
  end

  defp prs(state, repo_key), do: Map.get(state.snapshots, repo_key, [])

  defp pr_tickets(state, repo_key, pr) do
    linked = for link <- pr["links"] || [], do: link["bead_id"]
    by_branch = Map.get(state.branches, {repo_key, pr["source_branch"]}, [])

    (linked ++ by_branch)
    |> Enum.uniq()
    |> Enum.flat_map(fn id ->
      case state.by_key[{repo_key, id}] do
        nil -> []
        ticket -> [ticket]
      end
    end)
  end

  defp ticket_prs(state, t) do
    Enum.filter(prs(state, t.repo_key), fn pr ->
      Enum.any?(pr_tickets(state, t.repo_key, pr), &(key(&1) == key(t)))
    end)
  end

  defp live?(t), do: t.stage not in ["done", "abandoned"] and t.raw["status"] != "closed"
  defp parked?(t), do: t.raw["status"] in @parked

  defp pending?(state, t),
    do: Enum.any?(Map.get(state.by_ticket, key(t), []), &(&1.state == "pending"))

  defp past_close_out?(state, t) do
    Enum.any?(Map.get(state.by_ticket, key(t), []), &(&1.kind == "push" and &1.state == "done")) or
      Enum.any?(ticket_prs(state, t), &(&1["state"] in ["open", "merged"]))
  end

  defp stage_kind(state, t) do
    cond do
      t.stage == "reported" ->
        "report"

      t.stage == "committed" and push_repo?(state.repos, t.repo_key) and
          not Enum.any?(
            Map.get(state.by_ticket, key(t), []),
            &(&1.kind == "push" and &1.state in ["approved", "executing", "done"])
          ) ->
        "push"

      true ->
        nil
    end
  end

  defp stuck_item(state, t, kind, blocks) do
    cards = Map.get(state.by_ticket, key(t), [])
    last = List.last(cards)
    changed = time(t.stage_changed_at) || DateTime.from_unix!(0)

    since =
      case last do
        nil -> changed
        card -> Enum.max([changed, card.updated_at], DateTime)
      end

    %{
      repo_key: t.repo_key,
      bead_id: t.bead_id,
      title: t.raw["title"] || t.bead_id,
      kind: kind,
      stage: t.stage,
      blocks: blocks,
      since: since,
      fingerprint:
        Enum.join(
          [
            kind,
            t.stage,
            DateTime.to_iso8601(changed),
            if(last, do: "#{last.id}:#{last.state}", else: "-"),
            length(cards)
          ],
          "|"
        )
    }
  end

  defp key(t), do: {t.repo_key, t.bead_id}
  defp push_repo?(repos, key), do: Enum.any?(repos, &(&1["key"] == key and &1["forge"] != "none"))

  defp time(%DateTime{} = time), do: time
  defp time(%NaiveDateTime{} = time), do: DateTime.from_naive!(time, "Etc/UTC")

  defp time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, time, _} -> time
      _ -> nil
    end
  end

  defp time(_), do: nil

  defp covered_pr?(requests, repo, pr, tickets) do
    ids = Enum.map(tickets, & &1.bead_id)

    Enum.any?(requests, fn r ->
      r.repo_key == repo and r.state == "pending" and
        (r.bead_id in ids or r.facts["number"] == pr["number"])
    end)
  end
end
