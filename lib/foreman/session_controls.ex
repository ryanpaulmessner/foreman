defmodule Foreman.SessionControls do
  @moduledoc """
  The session page's live controls (spec Decisions 17-18, R3, R6, R11).

  `controls/2` says which controls work now, from the lifecycle machine
  (`Foreman.SessionLifecycle`): a control is on when the machine accepts its event in the
  row's state, with the row's kind as the guard. Off controls carry the reason the page
  shows. Park is not a control of a build at all.

  `run/4` fires the control's event through `Foreman.AgentSessions.fire/3` and runs the
  machine's effects on the row's own pane (`Foreman.SessionPane`), never on a window:
  Focus shows the pane, Send message types one line through the existing reply path,
  Continue types `continue` and Enter, Park and Stop save the capture and then close only
  that pane. Park and Stop run their effects inside the transaction that ends the row, so
  a failed capture or close leaves the row live.

  The ended-session controls (Decision 17 dead rows, R4, R8): Resume, Relaunch build on
  this ticket and Start fresh run through `Foreman.SessionResume`.
  """
  alias Foreman.{AgentSession, AgentSessions, SessionCaptures, SessionLifecycle, SessionPane}
  alias Foreman.SessionResume

  # Each control fires the lifecycle event of the same name.
  @controls [:focus, :message, :continue, :park, :stop]
  @dead [:resume, :relaunch_build, :start_fresh]

  @doc """
  The controls of `row`, in page order: a list of `{control, :on}` or
  `{control, {:off, reason}}`. Controls: `:answer`, the dead controls `:resume`,
  `:relaunch_build` (builds) and `:start_fresh` (coordinators), then `:continue`,
  `:focus`, `:message`, `:park` (coordinators only) and `:stop`; `:retry` (Try again now)
  is on only while tmux does not answer. A live session lists no dead control; a dead one
  lists Resume (on, or off with why it cannot resume) and, when it cannot resume, the
  control R4 offers in its place. Options: `:cards` (open card count) and `:tmux`
  (`:live`, `:connecting` or `:tmux_error`).
  """
  def controls(%AgentSession{} = row, opts \\ []) do
    cards = Keyword.get(opts, :cards, 0)
    tmux_down? = Keyword.get(opts, :tmux) == :tmux_error and is_nil(row.ended_at)

    live =
      for control <- [:continue, :focus, :message, :park, :stop],
          control != :park or row.kind != "build",
          do: {control, live(row, control, tmux_down?)}

    [{:answer, if(cards > 0, do: :on, else: {:off, "No card is open."})}] ++
      dead(row) ++ live ++ if(tmux_down?, do: [{:retry, :on}], else: [])
  end

  # R4: Resume when its conditions hold; otherwise Relaunch build or Start fresh.
  defp dead(row) do
    if SessionLifecycle.live?(SessionLifecycle.load(row.state)) do
      []
    else
      resumable? = AgentSessions.resumable?(row)
      resume = {:resume, if(resumable?, do: :on, else: {:off, resume_reason(row)})}

      cond do
        resumable? -> [resume]
        AgentSessions.allowed?(row, :relaunch_build) -> [resume, {:relaunch_build, relaunch(row)}]
        AgentSessions.allowed?(row, :start_fresh) -> [resume, {:start_fresh, :on}]
        true -> [resume]
      end
    end
  end

  # R8: a dead coordinator resumes first; one that cannot resume cannot take the note.
  defp relaunch(row) do
    case AgentSessions.coordinator(row) do
      nil ->
        {:off, "No coordinator is recorded for it."}

      %{ended_at: nil} ->
        :on

      coordinator ->
        if AgentSessions.resumable?(coordinator),
          do: :on,
          else: {:off, "#{coordinator.name} ended and cannot resume."}
    end
  end

  @doc "Why a dead session cannot resume (Decision 17's off reasons)."
  def resume_reason(%{harness: "pi", conversation_id: id}) when id in [nil, ""],
    do: "No Pi session id was recorded at launch."

  def resume_reason(%{harness: "pi", workdir: dir}) do
    if is_binary(dir) and File.dir?(dir),
      do: "The Pi session file is not available.",
      else: "The worktree was removed."
  end

  def resume_reason(_), do: "The board has no conversation id for it."

  defp live(row, control, tmux_down?) do
    state = SessionLifecycle.load(row.state)

    cond do
      not SessionLifecycle.live?(state) ->
        {:off, "The pane is closed."}

      control == :park and row.kind == "main_coordinator" ->
        {:off, "The main coordinator does not park."}

      tmux_down? ->
        {:off, "tmux does not answer."}

      not allowed?(row, control) ->
        {:off, reason(control, state)}

      true ->
        :on
    end
  end

  defp allowed?(row, control) do
    data = %{kind: row.kind, harness: row.harness}
    state = SessionLifecycle.load(row.state)
    not match?({:error, _}, SessionLifecycle.step(state, control, data))
  end

  defp reason(:continue, _), do: "Only after a usage limit."
  defp reason(:message, :waiting_usage_limit), do: "Use Continue at a usage limit."

  defp reason(:message, :waiting_permission),
    do: "Answer the permission prompt in the terminal first."

  defp reason(:message, _), do: "The agent is working. A message now interrupts it."

  @doc """
  Runs `control` (`:focus`, `:message`, `:continue`, `:park` or `:stop`) on `row`. The
  dead controls (`:resume`, `:relaunch_build`, `:start_fresh`) return what
  `Foreman.SessionResume` returns.
  `params` holds `text` for `:message`. Returns `:ok`, `{:ok, :no_client}` (Focus with no
  attached terminal) or `{:error, reason}`: `:invalid` (not available in this state),
  `:tmux_unavailable`, `:window_gone`, `:pane_changed`, `:prompt_busy`, `:answer_required`
  (an empty message), `:not_found` or the preview's refusal. Options go to tmux (`:runner`,
  `:key_delay`).
  """
  def run(row, control, params \\ %{}, opts \\ [])

  def run(%AgentSession{} = row, control, params, opts) when control in @controls do
    with :ok <- Foreman.Preview.allow_external_write(),
         :ok <- text(control, params),
         %AgentSession{} = row <- AgentSessions.get(row.id) || {:error, :not_found},
         {:ok, pane} <- SessionPane.resolve(row, opts) do
      # Park and Stop end the row: their effects run inside its transaction. The other
      # controls leave the state as it is and run after the machine accepts them.
      inside = if control in [:park, :stop], do: &effects(&1, &2, pane, params, opts)

      case AgentSessions.fire(row, control, run: inside) do
        {:ok, _row, _effects} when inside != nil -> :ok
        {:ok, row, effects} -> effects(row, effects, pane, params, opts)
        {:error, {:invalid, _, _}} -> {:error, :invalid}
        {:error, _} = error -> error
      end
    end
  end

  def run(%AgentSession{} = row, control, _params, opts) when control in @dead do
    apply(SessionResume, control, [row, opts])
  end

  def run(_, _, _, _), do: {:error, :invalid}

  defp text(:message, params) do
    case Foreman.ChatPrompt.typed(params["text"] || params[:text]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp text(_, _), do: :ok

  # Effects run in the machine's order; the first failure stops the rest.
  defp effects(row, effects, pane, params, opts) do
    Enum.reduce_while(effects, :ok, fn effect, :ok ->
      case effect(effect, row, pane, params, opts) do
        :ok -> {:cont, :ok}
        {:ok, :no_client} = shown -> {:halt, shown}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp effect({:show, :pane}, row, pane, _params, opts) do
    case Foreman.RequestSource.focus(SessionPane.source(row, pane), opts) do
      {:error, :no_client} -> {:ok, :no_client}
      other -> other
    end
  end

  defp effect({:send, :message}, row, pane, params, opts) do
    Foreman.SessionTmux.reply_source(
      SessionPane.source(row, pane),
      params["text"] || params[:text],
      opts
    )
  end

  defp effect({:send, :continue}, _row, pane, _params, opts), do: SessionPane.continue(pane, opts)

  defp effect({:save, :capture}, row, pane, _params, opts) do
    reason = if row.state == "parked", do: :park, else: :stop
    target = %{socket: pane.socket, target: pane.pane}

    case SessionCaptures.capture(row, reason, Keyword.put(opts, :target, target)) do
      {:ok, _} -> :ok
      {:error, :tmux_unavailable} = error -> error
      {:error, _} -> {:error, :capture_failed}
    end
  end

  defp effect({:close, :pane}, _row, pane, _params, opts), do: SessionPane.close(pane, opts)
end
