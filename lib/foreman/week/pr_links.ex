defmodule Foreman.Week.PrLinks do
  @moduledoc "Persistent ticket–PR history and cached ancestry, scoped to the configured remote."
  import Ecto.Query
  alias Foreman.Repo

  def record(key, remote, prs) do
    ids = Repo.all(from t in "tickets", where: t.repo_key == ^key, select: t.bead_id)
    prefixes = ids |> Enum.map(&(String.split(&1, "-", parts: 2) |> hd())) |> Enum.uniq()
    now = DateTime.utc_now()

    for pr <- prs,
        is_integer(pr["number"]) and is_binary(pr["url"]) and is_binary(pr["head_sha"]),
        link <- Enum.flat_map(prefixes, &Foreman.Forge.Stack.links(pr, &1)),
        link["bead_id"] in ids do
      row = %{
        repo_key: key,
        remote: remote,
        ticket_id: link["bead_id"],
        number: pr["number"],
        url: pr["url"],
        base_branch: pr["target_branch"],
        head_sha: pr["head_sha"],
        state: pr["state"],
        first_seen_at: now,
        last_seen_at: now
      }

      Repo.insert_all("week_pr_links", [row],
        conflict_target: [:repo_key, :remote, :ticket_id, :number],
        on_conflict: {:replace, [:url, :base_branch, :state, :last_seen_at]}
      )

      # A changed head invalidates ancestry; an unchanged head keeps its last good cache.
      Repo.update_all(
        from(p in "week_pr_links",
          where:
            p.repo_key == ^key and
              p.remote == ^remote and p.number == ^pr["number"] and p.head_sha != ^pr["head_sha"]
        ),
        set: [head_sha: pr["head_sha"], in_production: nil, in_staging: nil, checked_at: nil]
      )
    end

    :ok
  end

  def list(key, remote) do
    Repo.all(
      from p in "week_pr_links",
        where: p.repo_key == ^key and p.remote == ^remote,
        select:
          map(p, [
            :ticket_id,
            :number,
            :url,
            :base_branch,
            :head_sha,
            :state,
            :in_production,
            :in_staging,
            :checked_at,
            :first_seen_at,
            :last_seen_at
          ])
    )
  end
end
