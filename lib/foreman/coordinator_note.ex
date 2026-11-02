defmodule Foreman.CoordinatorNote do
  @moduledoc "One-shot notes to registered coordinators through the card-question delivery path."
  import Ecto.Query
  alias Foreman.Repo

  def send(actor, session, text, opts \\ [])

  def send("claude", session, text, opts) do
    with true <- valid_text?(session) and valid_text?(text),
         {:ok, message} <- Foreman.ChatPrompt.typed("[foreman note from #{session}] #{text}") do
      rows =
        Repo.all(
          from s in "sessions",
            where: s.repo_key == "__foreman__" and s.bead_id == "registered",
            order_by: s.id,
            select: %{window: s.window, details: s.details, ended_at: s.ended_at}
        )

      {delivered, skipped, _} =
        Enum.reduce(rows, {[], [], MapSet.new()}, fn row, {delivered, skipped, seen} ->
          recipient = %{name: row.details["session"], pane: row.window}

          result =
            cond do
              row.ended_at ->
                {:error, :session_ended}

              MapSet.member?(seen, row.window) ->
                {:error, :already_delivered}

              true ->
                Foreman.SessionTmux.reply_source(
                  %{server: :default, target: row.window, harness: row.details["harness"]},
                  message,
                  opts
                )
            end

          case result do
            :ok ->
              {[recipient | delivered], skipped, MapSet.put(seen, row.window)}

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

  defp valid_text?(text),
    do:
      is_binary(text) and String.valid?(text) and String.trim(text) != "" and
        not String.contains?(text, <<0>>)
end
