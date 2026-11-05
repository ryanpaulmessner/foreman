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
  """
  alias Foreman.{AgentSession, AgentSessions, SessionCaptures, SessionLifecycle, SessionPane}

  # Each control fires the lifecycle event of the same name.
  @controls [:focus, :message, :continue, :park, :stop]

  @doc """
  The controls of `row`, in page order: a list of `{control, :on}` or
  `{control, {:off, reason}}`. Controls: `:answer`, `:continue`, `:focus`, `:message`,
  `:park` (coordinators only) and `:stop`; `:retry` (Try again now) is on only while tmux
  does not answer. Options: `:cards` (open card count) and `:tmux` (`:live`,
  `:connecting` or `:tmux_error`).
  """
  def controls(%AgentSession{} = row, opts \\ []) do
    cards = Keyword.get(opts, :cards, 0)
    tmux_down? = Keyword.get(opts, :tmux) == :tmux_error and is_nil(row.ended_at)

    live =
      for control <- [:continue, :focus, :message, :park, :stop],
          control != :park or row.kind != "build",
          do: {control, live(row, control, tmux_down?)}

    [{:answer, if(cards > 0, do: :on, else: {:off, "No card is open."})}] ++
      live ++ if(tmux_down?, do: [{:retry, :on}], else: [])
  end

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
  Runs `control` (`:focus`, `:message`, `:continue`, `:park` or `:stop`) on `row`.
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
