defmodule Foreman.SessionCaptures do
  @moduledoc """
  The last pane output per session, for the dead view (spec Decision 15).

  Saved at agent exit (`foreman session capture`, run by the launch command after the
  agent ends), before Stop and Park (`capture/3`, called by those controls before they
  close the pane), and from the page's pane reader as a fallback (`poll`). A poll never
  replaces an exit, Stop or Park save: those describe how the session ended. A session
  that comes back to life (Resume) drops its old save, so its next save describes the new
  run.
  """
  import Ecto.Query
  alias Foreman.{AgentSession, AgentSessions, PaneCapture, Repo, SessionCapture}

  # A 200-line capture with colour codes is about 22 KB on average (research, fm-9mm.3).
  @max_bytes 1_000_000

  @doc "The saved capture of a session, or nil."
  def get(session_id) when is_binary(session_id) do
    case Ecto.UUID.cast(session_id) do
      {:ok, id} -> Repo.get(SessionCapture, id)
      :error -> nil
    end
  end

  def get(_), do: nil

  @doc """
  Saves `output` as the session's last output. `reason` is `:exit`, `:stop`, `:park` or
  `:poll`. Returns `{:ok, capture}`, `{:ok, :kept}` when a poll meets an exit, Stop or Park
  save, or `{:error, reason}`.
  """
  def save(session_id, output, reason, at \\ DateTime.utc_now())

  def save(session_id, output, reason, at) when is_atom(reason),
    do: save(session_id, output, Atom.to_string(reason), at)

  def save(session_id, output, reason, %DateTime{} = at) when is_binary(output) do
    cond do
      reason not in SessionCapture.reasons() -> {:error, :invalid_reason}
      byte_size(output) > @max_bytes -> {:error, :too_large}
      not String.valid?(output) -> {:error, :invalid_output}
      is_nil(AgentSessions.get(session_id)) -> {:error, :unknown_session}
      true -> upsert(session_id, output, reason, at)
    end
  end

  def save(_, _, _, _), do: {:error, :invalid_output}

  defp upsert(session_id, output, reason, at) do
    row = %{session_id: session_id, output: output, reason: reason, captured_at: at}
    replace = [set: [output: output, reason: reason, captured_at: at]]

    on_conflict =
      if reason == "poll",
        do: from(c in SessionCapture, where: c.reason == "poll", update: ^replace),
        else: replace

    case Repo.insert_all(SessionCapture, [row],
           on_conflict: on_conflict,
           conflict_target: :session_id,
           returning: true
         ) do
      {1, [capture]} -> {:ok, capture}
      {0, []} -> {:ok, :kept}
    end
  end

  @doc """
  Captures `row`'s pane now and saves it with `reason` (`:stop` or `:park`): the save Stop
  and Park run before they close the pane. Returns `{:ok, capture}` or
  `{:error, :tmux_unavailable}`; the caller decides whether to close the pane anyway.
  `:target` reads that `%{socket, target}` instead of the row's stored target (the
  controls pass the pane they checked); other options go to `Foreman.PaneCapture.read/2`.
  """
  def capture(%AgentSession{} = row, reason, opts \\ []) when reason in [:stop, :park] do
    target = Keyword.get_lazy(opts, :target, fn -> PaneCapture.target(row) end)

    with {:ok, output} <- PaneCapture.read(target, opts),
         do: save(row.id, output, reason)
  end

  @doc """
  The exit save sent by `foreman session capture` from the agent's own pane: the session
  is found as an ask's would be (`Foreman.AgentSessions.resolve_asker/1`). Returns
  `{:ok, capture}`, `{:unknown, warning}` or `{:error, reason}`.
  """
  def record_exit(%{"output" => output} = params) when is_binary(output) do
    case AgentSessions.resolve_asker(params) do
      {:ok, row} -> save(row.id, output, :exit)
      unknown -> unknown
    end
  end

  def record_exit(_), do: {:error, :invalid_output}

  @doc "Drops a session's save; called when a dead session comes back to life."
  def clear(session_id),
    do: Repo.delete_all(from c in SessionCapture, where: c.session_id == ^session_id)
end
