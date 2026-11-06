defmodule Foreman.QueuedNotes do
  @moduledoc """
  Notes for a coordinator that was busy (fm-9mm.23), on the `Foreman.QueuedNote` machine.

  When the board must type a note into a coordinator's pane (the R9 answer to an ended
  build's card, a Relaunch build note) and the prompt is mid-turn, `queue/1` saves the
  note in the caller's transaction. `run/1` is the note monitor's check: each waiting
  note whose coordinator row is live is claimed (saved as `sending` in its own
  transaction), then typed through the same idle-and-empty prompt test as every other
  reply (`Foreman.SessionTmux.reply_source/3`). One note per coordinator per check, in
  the order they were saved. A note is typed at most once: a claimed attempt that did
  not finish is failed, never retried. A note stays bound to its coordinator row: when
  that row ends, the note waits for it to resume and never goes to another session.

  Options of `run/1` go to tmux (`:runner`, `:socket`, `:key_delay`), over the
  `:session_controls_tmux` setting the answer path uses; `:now` sets the clock.
  """
  import Ecto.Query
  alias Foreman.{AgentSession, QueuedNote, Repo}
  alias Foreman.QueuedNotes.Note

  @open ~w(queued sending)

  @doc """
  Saves a waiting note. `attrs`: `kind` ("answer" or "relaunch"), `coordinator`
  (its `AgentSession` row), `text` (the whole message), and `subject_id` and
  `request_id` when known. A Relaunch build note for a build that already has one
  waiting returns that note. Returns `{:ok, note}`.
  """
  def queue(%{kind: kind, coordinator: %AgentSession{} = coordinator, text: text} = attrs)
      when kind in ["answer", "relaunch"] and is_binary(text) do
    case kind == "relaunch" && open_relaunch(attrs[:subject_id]) do
      %Note{} = note ->
        {:ok, note}

      _ ->
        :queued = QueuedNote.__fsm__(:initial)
        now = DateTime.utc_now()

        note =
          Repo.insert!(%Note{
            kind: kind,
            state: "queued",
            coordinator_id: coordinator.id,
            subject_id: attrs[:subject_id],
            request_id: attrs[:request_id],
            text: text,
            inserted_at: now,
            updated_at: now
          })

        notify(note, &Foreman.Events.broadcast/2)
        {:ok, note}
    end
  end

  @doc "True while `note` waits or is being typed."
  def waiting?(%{state: state}), do: state in @open
  def waiting?(_), do: false

  @doc "The open (waiting or being typed) Relaunch build note of build `subject_id`, or nil."
  def open_relaunch(nil), do: nil

  def open_relaunch(subject_id) do
    Repo.one(
      from n in Note,
        where: n.kind == "relaunch" and n.subject_id == ^subject_id and n.state in @open,
        limit: 1
    )
  end

  @doc "The note saved for card `request_id`, with its coordinator, or nil."
  def for_request(request_id) do
    Repo.one(from n in Note, where: n.request_id == ^request_id, preload: :coordinator)
  end

  @doc "Notes saved for the cards `ids`, by card id, with their coordinators."
  def for_requests([]), do: %{}

  def for_requests(ids) do
    Repo.all(from n in Note, where: n.request_id in ^ids, preload: :coordinator)
    |> Map.new(&{&1.request_id, &1})
  end

  @doc "Notes about session `subject_id`, newest first, with their coordinators."
  def for_subject(subject_id) do
    Repo.all(
      from n in Note,
        where: n.subject_id == ^subject_id,
        order_by: [desc: n.id],
        preload: :coordinator
    )
  end

  @doc "You stopped a waiting note. `{:ok, note}` or `{:error, :invalid | :not_found}`."
  def withdraw(id) do
    transaction(fn ->
      with %Note{} = note <- locked(id),
           {next, [save: :withdrawn]} <-
             QueuedNote.step(QueuedNote.load(note.state), :withdraw, %{}) do
        {:ok, save(note, state: to_string(next), done_at: DateTime.utc_now())}
      else
        nil -> {:error, :not_found}
        {:error, _} -> {:error, :invalid}
      end
    end)
  end

  @doc """
  One check: types at most one waiting note per live coordinator whose prompt is idle,
  and fails attempts that did not finish. A note whose coordinator is busy costs one
  read-only prompt check: no row write and no board event. Returns
  `%{sent: n, waiting: n, failed: n}`, or `{:error, reason}` in a preview, which never
  types. `:notify` (`fun(kind, key)`) replaces `Foreman.Events.broadcast/2`.
  """
  def run(opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write() do
      # Tests and the preview point tmux at stand-ins, as for every answer (`Requests`).
      opts = Keyword.merge(Application.get_env(:foreman, :session_controls_tmux, []), opts)
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

      notes =
        Repo.all(from n in Note, where: n.state in @open, order_by: n.id, preload: :coordinator)

      {_, counts} =
        Enum.reduce(notes, {MapSet.new(), %{sent: 0, waiting: 0, failed: 0}}, fn note, acc ->
          check(note, now, opts, acc)
        end)

      counts
    end
  end

  defp check(note, now, opts, {tried, counts}) do
    count = fn result -> Map.update!(counts, result, &(&1 + 1)) end

    if MapSet.member?(tried, note.coordinator_id) do
      {tried, count.(:waiting)}
    else
      case QueuedNote.step(QueuedNote.load(note.state), {:tick, tick(note, now)}, %{}) do
        {_, [save: :claim, type: :note]} ->
          tried = MapSet.put(tried, note.coordinator_id)
          {tried, count.(try_note(note, now, opts))}

        {_, [save: :lost]} ->
          {tried, count.(if(claim(note.id, now, opts) == :failed, do: :failed, else: :waiting))}

        _ ->
          {tried, count.(:waiting)}
      end
    end
  end

  defp tick(note, now),
    do: %{
      now: now,
      coordinator_live: is_nil(note.coordinator.ended_at),
      claimed_at: note.claimed_at
    }

  # A read-only prompt check first, so a busy coordinator costs no write; the claim is
  # still saved before any key is typed, and the typing path checks the prompt again.
  defp try_note(note, now, opts) do
    with :ok <-
           Foreman.SessionTmux.prompt_ready(Foreman.RequestSource.source(note.coordinator), opts),
         {:claimed, note} <- claim(note.id, now, opts) do
      attempt(note, opts)
    else
      :failed -> :failed
      _ -> :waiting
    end
  end

  # Saves the claim before any key is typed, so a crash cannot type the note twice. The
  # claim and its release are not shown, so they send no board event.
  defp claim(id, now, opts) do
    transaction(fn ->
      with %Note{} = note <- locked(id, :skip_locked) do
        coordinator = Repo.get!(AgentSession, note.coordinator_id)
        note = %{note | coordinator: coordinator}

        case QueuedNote.step(QueuedNote.load(note.state), {:tick, tick(note, now)}, %{}) do
          {next, [save: :claim, type: :note]} ->
            note = save(note, [state: to_string(next), claimed_at: now], nil)
            {:claimed, %{note | coordinator: coordinator}}

          {next, [save: :lost]} ->
            save(note, [state: to_string(next), reason: "lost", done_at: now], notifier(opts))
            :failed

          _ ->
            :skip
        end
      else
        _ -> :skip
      end
    end)
  end

  # Types a claimed note. Only a failure after the prompt check passed can have left text
  # in the pane; any earlier failure typed nothing, so the note waits again, unannounced.
  defp attempt(note, opts) do
    source = Foreman.RequestSource.source(note.coordinator)
    now = DateTime.utc_now()

    {event, changes, result} =
      case Foreman.SessionTmux.reply_source(source, note.text, [{:tag_typing, true} | opts]) do
        :ok ->
          {:typed, [done_at: now], :sent}

        {:error, {:typing, _}} ->
          {:typing_failed, [reason: "typing_failed", done_at: now], :failed}

        {:error, _} ->
          {:not_idle, [claimed_at: nil], :waiting}
      end

    notify = if result == :waiting, do: nil, else: notifier(opts)

    transaction(fn ->
      with %Note{state: "sending"} = current <- locked(note.id),
           {next, [save: _]} <- QueuedNote.step(:sending, event, %{}) do
        save(current, [{:state, to_string(next)} | changes], notify)
      end

      result
    end)
  end

  defp notifier(opts), do: Keyword.get(opts, :notify, &Foreman.Events.broadcast/2)

  defp locked(id), do: Repo.one(from n in Note, where: n.id == ^id, lock: "FOR UPDATE")

  # Another check holding the row is typing it: leave it alone.
  defp locked(id, :skip_locked),
    do: Repo.one(from n in Note, where: n.id == ^id, lock: "FOR UPDATE SKIP LOCKED")

  # `notify` is nil for changes no page shows (the claim and its release).
  defp save(note, changes, notify \\ &Foreman.Events.broadcast/2) do
    note =
      note
      |> Ecto.Changeset.change(Keyword.put(changes, :updated_at, DateTime.utc_now()))
      |> Repo.update!()

    if notify, do: notify(note, notify)
    note
  end

  # Pages that show the note reload: the card's Needs you and the session pages.
  defp notify(%Note{request_id: id}, notify) when is_binary(id),
    do: notify.(:requests_changed, id)

  defp notify(%Note{subject_id: id}, notify) when is_binary(id),
    do: notify.(:sessions_changed, id)

  defp notify(_, _), do: :ok

  defp transaction(fun) do
    {:ok, result} = Repo.transaction(fun)
    result
  end
end
