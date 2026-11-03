defmodule Foreman.CloseOutNags do
  @moduledoc """
  Sends the owning coordinator a note about stuck agent close-out work, on the
  `Foreman.CloseOutNag` schedule. Stuck work never goes to Needs you.

  The owner is the coordinator recorded on the ticket's latest dispatch. Each run sends
  at most one note per owner, naming every due ticket that fits in one note. Each
  attempt is recorded in `close_out_nag_notes` (shown on the ticket's history): the
  result is `delivered`, `skipped` (with the pane reason) or `ownerless` (with why).
  """
  import Ecto.Query
  alias Foreman.{CloseOutNag, Repo, WaitingWithoutCard}

  @lock "foreman:close_out_nags"
  @prefix "[foreman note from board] "
  @max_bytes 2_000
  @intro "Close-out work waits on you."

  @doc """
  One pass. Options: `:now` (clock), `:deliver` (`fun(owner, text) -> :ok | {:error, reason}`),
  `:items` (stuck items; default `WaitingWithoutCard.stuck/0`).
  """
  def run(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    deliver = Keyword.get(opts, :deliver, &Foreman.CoordinatorNote.send_to/2)

    with :ok <- Foreman.Preview.allow_external_write() do
      {:ok, result} =
        Repo.transaction(
          fn ->
            %{rows: [[locked]]} =
              Repo.query!("SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))", [@lock])

            if locked do
              items = Keyword.get_lazy(opts, :items, &WaitingWithoutCard.stuck/0)
              pass(items, now, deliver)
            else
              {:ok, :locked}
            end
          end,
          timeout: :infinity
        )

      result
    end
  end

  @doc "Note attempts for a ticket, oldest first."
  def history({repo, id}) do
    Repo.all(
      from n in "close_out_nag_notes",
        where: n.repo_key == ^repo and n.bead_id == ^id,
        order_by: n.id,
        select: map(n, [:id, :kind, :owner, :result, :reason, :text, :inserted_at])
    )
  end

  @doc """
  The coordinator that owns the ticket's close-out: the one recorded on its latest dispatch,
  or, for work a coordinator built and committed itself, that coordinator's session.
  `{:ok, name}` or `{:error, reason}`.
  """
  def owner({repo, id}) do
    event =
      Repo.one(
        from e in "stage_events",
          where:
            e.repo_key == ^repo and e.bead_id == ^id and e.outcome == "row" and
              (e.event == "dispatch" or (e.event == "commit" and e.source == "coordinator")),
          order_by: [desc: e.id],
          limit: 1,
          select: %{event: e.event, payload: e.payload}
      )

    case event do
      nil -> {:error, "not dispatched"}
      %{event: "dispatch", payload: %{"coordinator" => name}} when is_binary(name) -> {:ok, name}
      %{event: "commit", payload: %{"session" => name}} when is_binary(name) -> {:ok, name}
      %{event: "dispatch"} -> {:error, "no coordinator recorded on dispatch"}
      %{event: "commit"} -> {:error, "no session recorded on the coordinator's commit"}
    end
  end

  @doc "One line for a stuck item: the ticket, what is missing, and the next command."
  def line(%{bead_id: id, repo_key: repo} = item) do
    case item.kind do
      "report" ->
        "#{id} (#{repo}): the report is not reviewed. Next: foreman review #{id}, then close out."

      "push" ->
        "#{id} (#{repo}): the work is committed and has no push card. Next: foreman ask push #{id} --worktree <path> --branch <branch> --sha <sha> --remote-branch <branch>."

      "decision" ->
        "#{id} (#{repo}): this decision blocks #{blocks(item.blocks || [])} and has no card. Next: foreman ask decision #{id} --question \"<question>\" --option \"<A>\" --option \"<B>\"."
    end
  end

  defp pass(items, now, deliver) do
    rows =
      Repo.all(from n in "close_out_nags", select: map(n, ^fields()))
      |> Map.new(&{{&1.repo_key, &1.bead_id}, &1})

    keys = MapSet.new(items, &{&1.repo_key, &1.bead_id})

    for {key, row} <- rows, not MapSet.member?(keys, key), row.state != "cleared" do
      {:cleared, [save: :cleared]} = CloseOutNag.step(state(row), :resolved, data(row))
      save(row, state: "cleared")
    end

    due =
      for item <- items,
          row = sync(rows[{item.repo_key, item.bead_id}], item, now),
          {_, [note: :owner]} <- [CloseOutNag.step(state(row), {:tick, %{now: now}}, data(row))],
          do: {item, row}

    due
    |> Enum.group_by(fn {item, _} -> owner({item.repo_key, item.bead_id}) end)
    |> Enum.each(fn
      {{:ok, name}, group} ->
        sent = fit(group)
        text = Enum.join([@intro | Enum.map(sent, fn {item, _} -> line(item) end)], " ")

        {event, result, reason} =
          case deliver.(name, text) do
            :ok -> {:delivered, "delivered", nil}
            {:error, :prompt_busy} -> {:pane_busy, "skipped", reason_text(:prompt_busy)}
            {:error, reason} -> {:skipped, "skipped", reason_text(reason)}
          end

        Enum.each(sent, &attempt(&1, event, %{owner: name, result: result, reason: reason}, now))

      {{:error, why}, group} ->
        Enum.each(
          group,
          &attempt(&1, :no_owner, %{owner: nil, result: "ownerless", reason: why}, now)
        )
    end)

    {:ok, length(due)}
  end

  defp blocks(ids) when length(ids) > 5,
    do: Enum.join(Enum.take(ids, 5), ", ") <> " and #{length(ids) - 5} more"

  defp blocks(ids), do: Enum.join(ids, ", ")

  defp sync(nil, item, now) do
    :waiting = CloseOutNag.__fsm__(:initial)

    Repo.insert_all("close_out_nags", [
      %{
        repo_key: item.repo_key,
        bead_id: item.bead_id,
        kind: item.kind,
        state: "waiting",
        fingerprint: item.fingerprint,
        stuck_since: item.since,
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.one!(
      from n in "close_out_nags",
        where: n.repo_key == ^item.repo_key and n.bead_id == ^item.bead_id,
        select: map(n, ^fields())
    )
  end

  defp sync(row, item, _now) when row.fingerprint == item.fingerprint and row.state != "cleared",
    do: row

  defp sync(row, item, _now) do
    {:waiting, [save: :restart]} = CloseOutNag.step(state(row), :changed, data(row))

    changes = [
      state: "waiting",
      kind: item.kind,
      fingerprint: item.fingerprint,
      stuck_since: item.since,
      last_noted_at: nil
    ]

    save(row, changes)
    Map.merge(row, Map.new(changes))
  end

  defp attempt({item, row}, event, note, now) do
    {next, [save: :attempt]} = CloseOutNag.step(state(row), event, data(row))

    Repo.insert_all("close_out_nag_notes", [
      Map.merge(note, %{
        repo_key: item.repo_key,
        bead_id: item.bead_id,
        kind: item.kind,
        text: line(item),
        inserted_at: now
      })
    ])

    save(row, state: to_string(next), last_noted_at: now)
  end

  defp reason_text(:prompt_busy), do: "pane busy"
  defp reason_text(:window_gone), do: "pane gone"
  defp reason_text(:session_ended), do: "session ended"
  defp reason_text(:not_registered), do: "coordinator not registered"
  defp reason_text(:invalid_note), do: "note not valid"
  defp reason_text(reason), do: reason |> to_string() |> String.replace("_", " ")

  defp fit(group) do
    budget = @max_bytes - byte_size(@prefix) - byte_size(@intro)

    group
    |> Enum.reduce_while({[], budget}, fn entry, {sent, left} ->
      size = byte_size(line(elem(entry, 0))) + 1

      if size <= left or sent == [],
        do: {:cont, {[entry | sent], left - size}},
        else: {:halt, {sent, left}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp save(row, changes) do
    Repo.update_all(from(n in "close_out_nags", where: n.id == ^row.id),
      set: Keyword.put(changes, :updated_at, DateTime.utc_now())
    )
  end

  defp fields,
    do: [
      :id,
      :repo_key,
      :bead_id,
      :kind,
      :state,
      :fingerprint,
      :stuck_since,
      :last_noted_at
    ]

  defp state(row), do: Enum.find(CloseOutNag.__fsm__(:states), &(to_string(&1) == row.state))

  defp data(row),
    do: %{
      stuck_since: utc(row.stuck_since),
      last_noted_at: utc(row.last_noted_at)
    }

  defp utc(%NaiveDateTime{} = time), do: DateTime.from_naive!(time, "Etc/UTC")
  defp utc(time), do: time
end
