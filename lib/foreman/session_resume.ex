defmodule Foreman.SessionResume do
  @moduledoc """
  The ended-session controls and where an answer to an ended session goes (spec Decisions 7,
  17 and 20, rules R4, R8, R9 and R10).

  - `resume/2`: the same row opens its own conversation again (`resume`). A board-launched
    coordinator resumes through `Foreman.Sessions`, which moves its planning session and
    its row together; every other row opens a new pane through `Foreman.SessionLaunch`
    inside the transaction that makes the row live, so a failed open leaves it ended.
  - `relaunch_build/2`: a dead build that cannot resume asks its coordinator to relaunch it
    (`relaunch_build`). A dead coordinator resumes first, with the note as its first
    message (R8); a live one gets the note in its pane.
  - `start_fresh/2`: a dead coordinator that cannot resume gets a new row with the same
    name and parent and a new Claude conversation; its live sessions move to the new row
    (`start_fresh`). The old row stays ended.
  - `answer_route/1` and `deliver_answer/2` (R9): an answer to a card of an ended session
    resumes it first when it can, with the answer as its first message; otherwise it goes
    to its coordinator as a note with the question. A live coordinator that is mid-turn
    gets the note when its prompt is next idle (`Foreman.QueuedNotes`, fm-9mm.23). When
    the note cannot be delivered or saved, the answer is refused, so the card stays open
    and the answer never goes nowhere.

  Every write checks the lifecycle first and refuses in a preview. Options go to tmux and
  the launchers (`:runner`, `:executables`, `:executable`, `:socket`).
  """
  import Ecto.Query

  alias Foreman.{
    AgentSession,
    AgentSessions,
    PlanningSession,
    QueuedNotes,
    Repo,
    SessionLaunch,
    Sessions
  }

  @prefix "[foreman note from board] "

  @doc "Resumes `row`. Returns `{:ok, row}` (now live) or `{:error, reason}`."
  def resume(%AgentSession{} = row, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write(),
         {:ok, row} <- current(row),
         :ok <- allowed(row, :resume) do
      case planning(row) do
        nil -> own_resume(row, opts)
        planning -> board_resume(row, planning, opts)
      end
    end
  end

  defp own_resume(row, opts) do
    run = fn row, _effects ->
      with {:ok, pane} <- SessionLaunch.resume(row, opts) do
        AgentSessions.opened_pane(row, pane)
        :ok
      end
    end

    case AgentSessions.fire(row, :resume, run: run) do
      {:ok, _row, _} -> {:ok, AgentSessions.get(row.id)}
      {:error, {:invalid, _, _}} -> {:error, :invalid}
      error -> error
    end
  end

  # The planning session's own resume moves the row (`AgentSessions.sync_planning/2`).
  defp board_resume(row, planning, opts) do
    result =
      if Sessions.coordinator?(planning) do
        workdir = if row.workdir && File.dir?(row.workdir), do: [workdir: row.workdir], else: []
        Sessions.launch_coordinator(:resume, opts ++ workdir)
      else
        Sessions.relaunch({planning.project, planning.ticket}, opts)
      end

    with {:ok, _} <- result do
      case AgentSessions.get(row.id) do
        %AgentSession{ended_at: nil} = row -> {:ok, row}
        _ -> {:error, :not_resumable}
      end
    end
  end

  defp planning(row),
    do: Repo.one(from p in PlanningSession, where: p.session_id == ^row.id, limit: 1)

  @doc """
  Relaunch build on this ticket. Returns `{:ok, %{coordinator: name, resumed: boolean,
  queued: boolean, note: text}}` or `{:error, reason}`: `:no_coordinator`,
  `:coordinator_not_resumable`, or `{:coordinator, name, reason}` when the note could not
  reach it. A live coordinator that is busy gets the note when its prompt is next idle
  (`queued: true`, fm-9mm.23); while that note waits, pressing again adds no note.
  """
  def relaunch_build(%AgentSession{} = row, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write(),
         {:ok, row} <- current(row),
         :ok <- allowed(row, :relaunch_build),
         %AgentSession{} = coordinator <-
           AgentSessions.coordinator(row) || {:error, :no_coordinator} do
      note = relaunch_note(row)
      resumed = not is_nil(coordinator.ended_at)

      # Under the build's name lock (`AgentSessions.fire/3`): one open note per build, and
      # none is typed while one waits.
      run = fn _row, _effects ->
        if QueuedNotes.open_relaunch(row.id) do
          :ok
        else
          with {:ok, _} <-
                 note_or_queue(coordinator, note, opts, kind: "relaunch", subject_id: row.id),
               do: :ok
        end
      end

      case AgentSessions.fire(row, :relaunch_build, run: run) do
        {:ok, _, _} ->
          {:ok,
           %{
             coordinator: coordinator.name,
             resumed: resumed,
             queued: not is_nil(QueuedNotes.open_relaunch(row.id)),
             note: note
           }}

        {:error, {:invalid, _, _}} ->
          {:error, :invalid}

        error ->
          error
      end
    end
  end

  @doc "The relaunch note (Decision 17): `Relaunch the build for <ticket> on <branch>.`"
  def relaunch_note(row),
    do: "Relaunch the build for #{row.ticket || row.name} on #{row.branch || "its branch"}."

  @doc """
  Start fresh. Returns `{:ok, new_row}` or `{:error, reason}` (`:name_taken` when a live
  session already has the name).
  """
  def start_fresh(%AgentSession{} = row, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write(),
         {:ok, row} <- current(row),
         :ok <- allowed(row, :start_fresh) do
      id = Ecto.UUID.generate()

      run = fn row, _effects ->
        # Under the name lock: no live session may hold the name when the agent starts.
        with nil <- AgentSessions.live_by_name(row.name),
             {:ok, pane} <- SessionLaunch.fresh(row, id, opts),
             {:ok, new} <- AgentSessions.create(fresh_fields(row, id, pane), :launch) do
          AgentSessions.move_children(row, new)
          :ok
        else
          %AgentSession{} -> {:error, :name_taken}
          {:error, %Ecto.Changeset{}} -> {:error, :invalid}
          error -> error
        end
      end

      case AgentSessions.fire(row, :start_fresh, run: run) do
        {:ok, _, _} -> {:ok, AgentSessions.get(id)}
        {:error, {:invalid, _, _}} -> {:error, :invalid}
        error -> error
      end
    end
  end

  defp fresh_fields(row, id, pane) do
    now = DateTime.utc_now()

    %{
      id: id,
      name: row.name,
      kind: row.kind,
      parent_id: row.parent_id,
      harness: "claude",
      model: row.model,
      conversation_id: id,
      tmux_server: row.tmux_server,
      pane_id: pane,
      project: row.project,
      ticket: row.ticket,
      workdir: row.workdir,
      started_at: now,
      last_seen_at: now
    }
  end

  @doc """
  Where an answer to `request`'s card goes (R9): `:live` (its session gets it as today),
  `{:resume, row}` (an ended session that can resume), `{:note, coordinator}` (an ended
  session that cannot: its live or resumable coordinator), or `:none` (nobody gets it:
  an unknown source, or an ended session with no coordinator that can take a note).
  """
  def answer_route(request) do
    case Foreman.RequestSource.row(request) do
      nil ->
        :none

      %AgentSession{ended_at: nil} ->
        :live

      row ->
        coordinator = AgentSessions.coordinator(row)

        cond do
          AgentSessions.resumable?(row) -> {:resume, row}
          coordinator && reachable?(coordinator) -> {:note, coordinator}
          true -> :none
        end
    end
  end

  defp reachable?(%AgentSession{ended_at: nil}), do: true
  defp reachable?(row), do: AgentSessions.resumable?(row)

  @doc """
  Delivers an answer to the card of an ended session (R9), inside the transaction that
  records it. Returns `:ok` or `{:error, {:not_delivered, name, reason}}`.
  """
  def deliver_answer(request, payload, opts \\ []) do
    case answer_route(request) do
      {:resume, row} ->
        message = @prefix <> answer_text(request, payload, :resumed)

        case resume(row, Keyword.put(opts, :prompt, message)) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:not_delivered, row.name, reason}}
        end

      {:note, coordinator} ->
        text = answer_text(request, payload, {:for, source_name(request)})
        subject = Foreman.RequestSource.row(request)

        case note_or_queue(coordinator, text, opts,
               kind: "answer",
               subject_id: subject && subject.id,
               request_id: request.id
             ) do
          {:ok, _} -> :ok
          {:error, {:coordinator, name, reason}} -> {:error, {:not_delivered, name, reason}}
        end

      _ ->
        :ok
    end
  end

  defp source_name(request) do
    case Foreman.RequestSource.row(request) do
      %AgentSession{name: name} -> name
      _ -> "The session"
    end
  end

  # One line, at most about 1500 bytes: `foreman wait <id>` reads the full outcome.
  defp answer_text(request, payload, who) do
    lead =
      case who do
        :resumed -> "Ryan answered your card #{request.id} while this session was closed."
        {:for, name} -> "#{name} ended and cannot resume. Ryan answered its card #{request.id}."
      end

    note =
      if is_binary(payload["note"]) and String.trim(payload["note"]) != "", do: payload["note"]

    [
      lead,
      "Question: " <> clip(request.facts["question"] || "", 400),
      "Answer: " <> clip(answer(payload["answer"]), 500),
      note && "Note: " <> clip(note, 400),
      "Full outcome: foreman wait #{request.id}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp answer(answer) when is_binary(answer), do: answer
  defp answer(answer) when is_list(answer), do: Enum.map_join(answer, ", ", &to_string/1)
  defp answer(nil), do: ""
  defp answer(answer), do: Jason.encode!(answer)

  defp clip(text, max) do
    text = String.replace(text, ~r/\s+/u, " ") |> String.trim()
    if byte_size(text) <= max, do: text, else: String.slice(text, 0, div(max, 4)) <> "…"
  end

  # A note that finds a live coordinator mid-turn is saved and typed when its prompt is
  # next idle (fm-9mm.23). `{:ok, :sent | :queued}` or `{:error, {:coordinator, name, why}}`.
  defp note_or_queue(coordinator, text, opts, attrs) do
    case note(coordinator, text, opts) do
      :ok ->
        {:ok, :sent}

      {:error, {:coordinator, _, :prompt_busy}} when is_nil(coordinator.ended_at) ->
        attrs = Map.new(attrs) |> Map.merge(%{coordinator: coordinator, text: @prefix <> text})
        {:ok, _} = QueuedNotes.queue(attrs)
        {:ok, :queued}

      error ->
        error
    end
  end

  # A note to a coordinator: typed into its pane while it is live; a dead one resumes with
  # the note as its first message (R8).
  defp note(%AgentSession{ended_at: nil} = coordinator, text, opts) do
    case Foreman.SessionTmux.reply_source(
           Foreman.RequestSource.source(coordinator),
           @prefix <> text,
           opts
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:coordinator, coordinator.name, reason}}
    end
  end

  defp note(coordinator, text, opts) do
    if AgentSessions.resumable?(coordinator) do
      case resume(coordinator, Keyword.put(opts, :prompt, @prefix <> text)) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:coordinator, coordinator.name, reason}}
      end
    else
      {:error, {:coordinator, coordinator.name, :coordinator_not_resumable}}
    end
  end

  defp current(row) do
    case AgentSessions.get(row.id) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  defp allowed(row, event),
    do: if(AgentSessions.allowed?(row, event), do: :ok, else: {:error, :invalid})
end
