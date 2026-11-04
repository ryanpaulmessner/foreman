defmodule Foreman.CoordinatorNote do
  @moduledoc "One-shot notes to known sessions, found by their `agent_sessions` row, through the card-question delivery path."
  import Ecto.Query
  alias Foreman.{AgentSession, Repo}

  def send(actor, session, text, opts \\ [])

  def send("claude", session, text, opts) do
    with true <- valid_text?(session) and valid_text?(text),
         {:ok, message} <- Foreman.ChatPrompt.typed("[foreman note from #{session}] #{text}") do
      rows = recipients()

      {delivered, skipped, _} =
        Enum.reduce(rows, {[], [], MapSet.new()}, fn row, {delivered, skipped, seen} ->
          target = Foreman.AgentSessions.target(row)
          recipient = %{name: row.name, pane: target.target}

          result =
            cond do
              row.ended_at ->
                {:error, :session_ended}

              MapSet.member?(seen, {target.server, target.target}) ->
                {:error, :already_delivered}

              true ->
                deliver(target, message, opts)
            end

          case result do
            :ok ->
              {[recipient | delivered], skipped, MapSet.put(seen, {target.server, target.target})}

            {:error, reason} ->
              {delivered, [Map.put(recipient, :reason, to_string(reason)) | skipped], seen}
          end
        end)

      {:ok, %{delivered: Enum.reverse(delivered), skipped: Enum.reverse(skipped)}}
    else
      _ -> {:error, :invalid_note}
    end
  end

  def send(_, _, _, _), do: {:error, :coordinator_only}

  @doc """
  One note from the board to the session `name` (its live row, else its latest). Returns `:ok` or
  `{:error, reason}`: `:not_registered`, `:session_ended`, `:invalid_note`, or a pane
  reason such as `:prompt_busy` or `:window_gone`. Never queued.
  """
  def send_to(name, text, opts \\ []) do
    with true <- valid_text?(name) and valid_text?(text),
         {:ok, message} <- Foreman.ChatPrompt.typed("[foreman note from board] #{text}") do
      row =
        Repo.one(
          from s in AgentSession,
            where: s.name == ^name,
            order_by: [desc: is_nil(s.ended_at), desc: s.started_at],
            limit: 1
        )

      cond do
        is_nil(row) -> {:error, :not_registered}
        row.ended_at -> {:error, :session_ended}
        true -> deliver(Foreman.AgentSessions.target(row), message, opts)
      end
    else
      _ -> {:error, :invalid_note}
    end
  end

  defp deliver(target, message, opts), do: Foreman.SessionTmux.reply_source(target, message, opts)

  # Registered sessions, by their rows: each name once (its latest row), ended ones
  # reported as skipped. Dispatch-only rows were never recipients.
  defp recipients do
    registered =
      from r in "sessions",
        where:
          r.repo_key == "__foreman__" and r.bead_id == "registered" and
            not is_nil(r.agent_session_id),
        select: r.agent_session_id

    Repo.all(
      from s in AgentSession,
        where: s.id in subquery(registered),
        distinct: s.name,
        order_by: [asc: s.name, desc: is_nil(s.ended_at), desc: s.started_at]
    )
    |> Enum.sort_by(& &1.started_at, DateTime)
  end

  defp valid_text?(text),
    do:
      is_binary(text) and String.valid?(text) and String.trim(text) != "" and
        not String.contains?(text, <<0>>)
end
