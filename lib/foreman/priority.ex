defmodule Foreman.Priority do
  @moduledoc """
  Ticket priority, P0 (most urgent) to P4.

  The ticket file (or beads export) owns the value; the app never writes ticket
  files. A change made on the board is a Postgres override that wins over the
  file and shows as "changed on board" until a file sync carries the same value,
  which deletes it. Setting the file's own value deletes it too. Ownership is the
  `Foreman.PriorityOverride` machine; this module interprets its effects.

  "Jump to front" sets P0 and records the observed `jump` event on the ticket's
  stage machine. A jump is pending while the ticket is still queued; the
  coordinator reads pending jumps (`foreman ls --overlay --json`, `jumps`) first.
  """
  import Ecto.Query
  alias Foreman.{Overlay, PriorityOverride, Repo}

  @levels 0..4

  @doc "Sort rank: P0 first, a missing or malformed priority after P4."
  def rank(priority) when is_integer(priority) and priority in @levels, do: priority
  def rank(_), do: 5

  def levels, do: Enum.to_list(@levels)

  @doc "Effective priority per key: `%{priority, file, changed_on_board}`. Keys without a ticket are absent."
  def for_keys([]), do: %{}

  def for_keys(keys) do
    repos = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    ids = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    wanted = MapSet.new(keys)

    files =
      Repo.all(
        from b in "beads",
          where: b.repo_key in ^repos and b.bead_id in ^ids,
          select: {b.repo_key, b.bead_id, fragment("?->'priority'", b.raw)}
      )
      |> Enum.filter(fn {repo, id, _} -> MapSet.member?(wanted, {repo, id}) end)
      |> Map.new(fn {repo, id, priority} -> {{repo, id}, priority} end)

    overrides = override_map(repos)

    Map.new(files, fn {key, file} ->
      override = overrides[key]

      {key,
       %{
         priority: override || file,
         file: file,
         changed_on_board: not is_nil(override)
       }}
    end)
  end

  @doc "Every board override with the file value it differs from, newest first."
  def overrides do
    Repo.all(
      # Inner join: an override for a ticket that no longer exists is not listed,
      # so a coordinator never tries to write it to a missing ticket file.
      from o in "priority_overrides",
        join: b in "beads",
        on: b.repo_key == o.repo_key and b.bead_id == o.bead_id,
        order_by: [desc: o.updated_at, desc: o.id],
        select: %{
          repo: o.repo_key,
          id: o.bead_id,
          priority: o.priority,
          file_priority: fragment("?->'priority'", b.raw),
          actor: o.actor,
          at: o.updated_at
        }
    )
  end

  @doc "Sets a board priority for a ticket or epic in the projection."
  def set(key, priority, actor) do
    Repo.transaction(fn ->
      case put(key, priority, actor) do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Sets P0 on a queued ticket and records the board's `jump` event."
  def jump(key, actor) do
    Repo.transaction(fn ->
      with %{machine: Foreman.Stage, stage: :queued} <- Overlay.get(key) || :not_found,
           previous = Map.get(for_keys([key]), key, %{priority: nil}).priority,
           {:ok, 0} <- put(key, 0, actor),
           {:ok, %{effects: [_ | _]}} <-
             Overlay.apply_event(key, {:jump, %{priority: 0, previous: previous}}, %{
               actor: actor
             }) do
        0
      else
        :not_found -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:not_queued)
      end
    end)
  end

  @doc "Latest jump per still-queued ticket, newest first."
  def pending_jumps do
    latest =
      from e in "stage_events",
        where: e.event == "jump" and e.outcome == "row",
        group_by: [e.repo_key, e.bead_id],
        select: %{repo_key: e.repo_key, bead_id: e.bead_id, id: max(e.id)}

    Repo.all(
      from l in subquery(latest),
        join: e in "stage_events",
        on: e.id == l.id,
        join: t in "tickets",
        on: t.repo_key == l.repo_key and t.bead_id == l.bead_id,
        where: t.stage == "queued",
        order_by: [desc: e.id],
        select: %{repo: e.repo_key, id: e.bead_id, actor: e.actor, at: e.inserted_at}
    )
    |> Enum.map(&%{&1 | at: DateTime.from_naive!(&1.at, "Etc/UTC")})
  end

  @doc "After a file sync: overrides the file now carries go back to the file."
  def reconcile(repo_key) do
    Repo.all(
      from o in "priority_overrides",
        join: b in "beads",
        on: b.repo_key == o.repo_key and b.bead_id == o.bead_id,
        where: o.repo_key == ^repo_key,
        select: {o.bead_id, o.priority, o.actor, fragment("?->'priority'", b.raw)}
    )
    |> Enum.each(fn {id, priority, actor, file} ->
      {_, effects} =
        PriorityOverride.step(:board, {:synced, %{priority: priority, file: file}}, nil)

      apply_effects(effects, {repo_key, id}, priority, actor)
    end)

    :ok
  end

  @doc "Board overrides for these repos: `%{key => priority}`."
  def override_map(repos) do
    Repo.all(
      from o in "priority_overrides",
        where: o.repo_key in ^repos,
        select: {{o.repo_key, o.bead_id}, o.priority}
    )
    |> Map.new()
  end

  defp put(_key, priority, _actor) when not (is_integer(priority) and priority in @levels),
    do: {:error, :invalid_priority}

  defp put(key, priority, actor) do
    case for_keys([key]) do
      %{^key => current} ->
        state = if current.changed_on_board, do: :board, else: :file

        {_, effects} =
          PriorityOverride.step(state, {:set, %{priority: priority, file: current.file}}, nil)

        apply_effects(effects, key, priority, actor)
        {:ok, priority}

      _ ->
        {:error, :not_found}
    end
  end

  defp apply_effects(effects, key, priority, actor),
    do: Enum.each(effects, &apply_effect(&1, key, priority, actor))

  defp apply_effect({:store, :override}, {repo, id} = key, priority, actor) do
    now = DateTime.utc_now()

    Repo.insert_all(
      "priority_overrides",
      [
        %{
          repo_key: repo,
          bead_id: id,
          priority: priority,
          actor: actor,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:priority, :actor, :updated_at]},
      conflict_target: [:repo_key, :bead_id]
    )

    notify(key)
  end

  defp apply_effect({:clear, :override}, {repo, id} = key, _priority, _actor) do
    Repo.delete_all(
      from o in "priority_overrides", where: o.repo_key == ^repo and o.bead_id == ^id
    )

    notify(key)
  end

  defp notify({repo, id}), do: Foreman.Events.broadcast(:overlay_changed, repo <> "/" <> id)
end
