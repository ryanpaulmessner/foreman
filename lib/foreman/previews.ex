defmodule Foreman.Previews do
  @moduledoc "Durable preview intent. The web reads/queues; the worker alone invokes devserve."
  import Ecto.Query
  alias Foreman.{Repo, Overlay}
  alias Foreman.Previews.Machine

  @fields [
    :id,
    :worktree,
    :repo_key,
    :bead_id,
    :state,
    :launch_requested,
    :metadata,
    :error,
    :logs
  ]

  def observation(%{"state" => state}) do
    Enum.find([:starting, :running, :failed, :stopped], &(to_string(&1) == state))
  end

  def for_ticket(key) do
    case worktree(key) do
      nil ->
        nil

      path ->
        get_path(path) ||
          %{id: nil, worktree: path, state: :none, metadata: %{}, error: nil, logs: ""}
    end
  end

  def worktree({repo, id}) do
    details =
      Repo.one(
        from s in "sessions",
          where: s.repo_key == ^repo and s.bead_id == ^id,
          order_by: [desc: s.id],
          limit: 1,
          select: s.details
      )

    path = details && (details["workdir"] || details["worktree"])
    if is_binary(path) and Path.type(path) == :absolute, do: Path.expand(path)
  end

  def start({repo, id} = key) do
    Repo.transaction(fn ->
      # Same ordering as the overlay: a terminal stage cannot race a new start intent.
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "foreman:overlay:" <> repo
      ])

      with :ok <- Foreman.Preview.allow_external_write(),
           %{stage: stage} <- Overlay.get(key),
           false <- ended?(key, stage),
           path when is_binary(path) <- worktree(key),
           true <- File.dir?(path) do
        Repo.insert_all("previews", [%{worktree: path, repo_key: repo, bead_id: id}],
          on_conflict: :nothing
        )

        row =
          Repo.one(
            from p in "previews",
              where: p.worktree == ^path,
              lock: "FOR UPDATE",
              select: map(p, ^@fields)
          )
          |> decode()

        if row.state != :stopped and (row.repo_key != repo or row.bead_id != id),
          do: Repo.rollback(:worktree_in_use)

        transition!(row, :start, error: nil, launch_requested: true, repo_key: repo, bead_id: id)
        enqueue()
      else
        _ -> Repo.rollback(:unavailable)
      end
    end)
  end

  def stop(id) do
    Repo.transaction(fn ->
      if Foreman.Preview.allow_external_write() != :ok, do: Repo.rollback(:preview_read_only)

      row =
        Repo.one(
          from p in "previews", where: p.id == ^id, lock: "FOR UPDATE", select: map(p, ^@fields)
        )
        |> decode()

      case row do
        nil -> Repo.rollback(:not_found)
        row -> transition!(row, :stop, error: nil)
      end

      enqueue()
    end)
  end

  @doc """
  True when a ticket's preview should end: merged or abandoned, or done with no open PR.
  A ticket closed while its PR is still open keeps its preview for testing until the PR ends.
  """
  def ended?({repo, id}, stage) do
    stage in [:merged, :abandoned] or
      (stage == :done and
         not Repo.exists?(
           from c in "overlay_cr_links", where: c.repo_key == ^repo and c.bead_id == ^id
         ))
  end

  def cleanup({repo, id}) do
    rows =
      Enum.filter(all(), &(&1.repo_key == repo and &1.bead_id == id and &1.state != :stopped))

    Enum.each(rows, &transition!(&1, :stop, error: nil))
    if rows != [], do: enqueue()
    :ok
  end

  def enqueue do
    %{} |> Foreman.Previews.Job.new() |> Oban.insert!()
    :ok
  end

  def orphans do
    Enum.filter(all(), fn row ->
      ticket = row.repo_key && Overlay.get({row.repo_key, row.bead_id})

      row.state != :stopped and
        (row.metadata["missing"] == true or not File.dir?(row.worktree) or
           is_nil(ticket) or not is_nil(ticket.orphaned_at))
    end)
  end

  def all,
    do:
      Repo.all(from p in "previews", order_by: p.id, select: map(p, ^@fields))
      |> Enum.map(&decode/1)

  def get(id),
    do: Repo.one(from p in "previews", where: p.id == ^id, select: map(p, ^@fields)) |> decode()

  defp get_path(path),
    do:
      Repo.one(from p in "previews", where: p.worktree == ^path, select: map(p, ^@fields))
      |> decode()

  defp decode(nil), do: nil

  defp decode(row),
    do: %{row | state: Enum.find(Machine.__fsm__(:states), &(to_string(&1) == row.state))}

  def reconcile(adapter \\ Foreman.Previews.Devserve) do
    # Session lock, not a transaction: intents remain writable during slow CLI calls.
    # Multiple worker nodes serialize their IO, including an old job rescued by Oban.
    Repo.checkout(
      fn ->
        Repo.query!("SELECT pg_advisory_lock(hashtextextended('foreman:previews:worker', 0))")

        try do
          with {:ok, rows} <- adapter.list() do
            discover(rows)
            Enum.each(all(), &reconcile_one(&1, rows, adapter))
            :ok
          end
        after
          Repo.query!("SELECT pg_advisory_unlock(hashtextextended('foreman:previews:worker', 0))")
        end
      end,
      timeout: :timer.minutes(10)
    )
  end

  defp discover(rows) do
    Enum.each(rows, fn metadata ->
      path = metadata["worktree"]

      if is_nil(get_path(path)) do
        session =
          Repo.one(
            from s in "sessions",
              where:
                fragment(
                  "coalesce(?->>'workdir', ?->>'worktree') = ?",
                  s.details,
                  s.details,
                  ^path
                ),
              order_by: [desc: s.id],
              limit: 1,
              select: %{repo_key: s.repo_key, bead_id: s.bead_id}
          )

        Repo.insert_all(
          "previews",
          [Map.merge(%{worktree: path, metadata: metadata}, session || %{})],
          on_conflict: :nothing
        )
      end
    end)
  end

  defp reconcile_one(row, rows, adapter) do
    metadata = Enum.find(rows, &(&1["worktree"] == row.worktree))
    row = get(row.id)
    terminal = row.repo_key && Overlay.get({row.repo_key, row.bead_id})

    if terminal && ended?({row.repo_key, row.bead_id}, terminal.stage) &&
         (row.state != :stopped || not is_nil(metadata)),
       do: transition!(row, :stop)

    row = get(row.id)

    {_, [run: effect]} = Machine.step(row.state, :reconcile, row)

    case effect do
      :start ->
        result =
          if metadata && metadata["state"] in ["starting", "running"],
            do: :ok,
            else:
              adapter.up(
                row.worktree,
                "foreman:" <> (row.repo_key || "") <> ":" <> (row.bead_id || "")
              )

        Repo.update_all(from(p in "previews", where: p.id == ^row.id),
          set: [launch_requested: false]
        )

        # Re-read after IO: stop/stage cleanup wins over a late successful start.
        case adapter.list() do
          {:ok, fresh} ->
            current = get(row.id)
            meta = Enum.find(fresh, &(&1["worktree"] == row.worktree))

            if current.state == :stopping do
              stop_preview(current, meta, adapter)
            else
              observe(current, meta, adapter, result)
            end

          {:error, reason} ->
            set_error(row.id, reason)
        end

      :stop ->
        stop_preview(row, metadata, adapter)

      _ ->
        observe(row, metadata, adapter, :ok)
    end
  end

  defp stop_preview(row, nil, _adapter),
    do: transition!(row, :stopped, metadata: %{}, logs: "", error: nil)

  defp stop_preview(row, metadata, adapter) do
    case adapter.down(metadata["unit"]) do
      :ok -> transition!(row, :stopped, metadata: %{}, logs: "", error: nil)
      {:error, reason} -> set_error(row.id, reason)
    end
  end

  defp observe(row, nil, _adapter, result) do
    if match?({:error, _}, result),
      do: transition!(row, :failed, error: elem(result, 1)),
      else: transition!(row, :stopped, metadata: %{})
  end

  defp observe(row, metadata, adapter, result) do
    event = observation(metadata)

    logs =
      case adapter.logs(metadata["unit"]) do
        {:ok, text} -> String.slice(text, -16_384, 16_384)
        _ -> row.logs
      end

    error = if match?({:error, _}, result), do: elem(result, 1)
    if event, do: transition!(row, event, metadata: metadata, logs: logs, error: error)
  end

  defp set_error(id, reason),
    do:
      Repo.update_all(from(p in "previews", where: p.id == ^id), set: [error: to_string(reason)])

  defp transition!(row, event, changes \\ []) do
    case Machine.step(row.state, event, %{}) do
      {state, []} ->
        changes =
          if event in [:stop, :stopped],
            do: Keyword.put(changes, :launch_requested, false),
            else: changes

        # Compare-and-swap prevents observations from overwriting newer user intent.
        Repo.update_all(
          from(p in "previews", where: p.id == ^row.id and p.state == ^to_string(row.state)),
          set: Keyword.put(changes, :state, to_string(state))
        )

      {:error, _} ->
        Repo.rollback(:busy)
    end
  end
end
