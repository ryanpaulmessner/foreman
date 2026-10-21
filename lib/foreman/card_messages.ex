defmodule Foreman.CardMessages do
  @moduledoc "Append-only conversation on a pending request; never resolves the request."
  import Ecto.Query
  alias Foreman.{CardMessage, Repo, Requests}

  def ask(id, body, opts \\ []) do
    if text?(body, 1_900) do
      pending(id, :card_question, fn request, [send: :prompt] ->
        with source when not is_nil(source) <- Foreman.RequestSource.for_request(request),
             :ok <- deliver(request, source, "[card question #{id}] " <> body, opts) do
          insert(request, "ryan", body)
        else
          nil -> {:error, :source_unknown}
          error -> error
        end
      end)
    else
      {:error, :invalid_message}
    end
  end

  def reply(id, actor, session, body) do
    if text?(actor, 200) and (is_nil(session) or text?(session, 500)) and text?(body, 20_000) do
      author = Enum.join(Enum.reject([actor, session], &is_nil/1), " · ")

      pending(id, :card_reply, fn request, [record: :message] -> insert(request, author, body) end)
    else
      {:error, :invalid_message}
    end
  end

  defp deliver(request, %{server: :board, target: window}, text, opts) do
    case Foreman.Sessions.get({request.repo_key, request.bead_id}) do
      %{session_id: id, window: ^window, state: state} = session
      when id == request.session and state in [:starting, :running, :waiting] ->
        Foreman.SessionTmux.reply_session(session, text, opts)

      _ ->
        {:error, :window_gone}
    end
  end

  defp deliver(%{facts: %{"target" => "external"} = facts}, source, text, opts) do
    Foreman.SessionTmux.reply_external(facts, text, Keyword.put(opts, :harness, source.harness))
  end

  defp deliver(_request, source, text, opts),
    do: Foreman.SessionTmux.reply_source(source, text, opts)

  def questioned?(id),
    do: Repo.exists?(from m in CardMessage, where: m.request_id == ^id and m.author == "ryan")

  def versions(ids) do
    Repo.all(
      from m in CardMessage,
        where: m.request_id in ^ids,
        group_by: m.request_id,
        select: {m.request_id, max(m.id)}
    )
    |> Map.new()
  end

  def list_many(ids) do
    Repo.all(from m in CardMessage, where: m.request_id in ^ids, order_by: m.id)
    |> Enum.group_by(& &1.request_id)
  end

  def list(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.all(from m in CardMessage, where: m.request_id == ^id, order_by: m.id)
      _ -> []
    end
  end

  defp text?(text, max),
    do:
      is_binary(text) and String.valid?(text) and byte_size(text) <= max and
        String.trim(text) != "" and not String.contains?(text, <<0>>)

  defp insert(request, author, body) do
    message = Repo.insert!(%CardMessage{request_id: request.id, author: author, body: body})
    Foreman.Events.broadcast(:requests_changed, request.id)
    {:ok, message}
  end

  defp pending(id, event, fun) do
    case Repo.transaction(fn ->
           case Requests.get(id) do
             nil ->
               {:error, :not_found}

             request ->
               Foreman.SessionWaiting.lock(request.repo_key)

               case Requests.get(id) do
                 %{state: "pending"} = request ->
                   {:pending, effects} =
                     Foreman.Request.step(:pending, event, Requests.context(request))

                   fun.(request, effects)

                 _ ->
                   {:error, :request_finished}
               end
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
