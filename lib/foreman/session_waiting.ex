defmodule Foreman.SessionWaiting do
  @moduledoc "Session attention requests. The repository lock serializes signals, deduplication and user clicks."
  @behaviour Foreman.Requests.Kind
  import Ecto.Query
  alias Foreman.{Repo, Requests, Sessions, PlanningSession, SessionTmux}
  alias Foreman.Requests.Request

  @impl true
  def validate(%{"reason" => reason} = facts, _)
      when reason in ~w(input permission usage_limit) do
    if Enum.all?(
         [facts["provider"], facts["reset_at"]],
         &(is_nil(&1) or Foreman.Requests.Decision.text?(&1))
       ) do
      {:ok,
       Map.take(
         facts,
         ~w(reason provider reset_at attach window pane pid target session_id snapshot tool)
       )}
    else
      {:error, :invalid_facts}
    end
  end

  def validate(_, _), do: {:error, :invalid_facts}
  @impl true
  def enqueue(_), do: {:error, :not_executable}

  def lock(project),
    do:
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "foreman:overlay:" <> project
      ])

  def ask({project, _} = key, params) do
    transaction(fn ->
      lock(project)

      with true <- Foreman.Requests.Decision.text?(params["session"]),
           {:ok, facts} <- validate(params["facts"], nil),
           {:ok, facts} <- target(key, params["session"], facts, params["facts"]) do
        existing = pending(key, params["session"])

        if turn_ended?(facts),
          do: wait_without_asking(key, params["session"], existing),
          else: ask_or_reuse(key, params, facts, existing)
      else
        false -> {:error, :session_required}
        error -> error
      end
    end)
  end

  # Questions and permission prompts carry a tool; a background agent's prompt can
  # outlive the main turn, so only tool-less waits end with it.
  defp wait_without_asking(key, session, existing) do
    for %{facts: facts} = request <- existing,
        is_nil(facts["tool"]),
        do: Requests.resolve(request.id, :facts_changed, %{"reason" => "session_idle"})

    Sessions.signal(key, session, :waiting)
  end

  defp ask_or_reuse(key, params, facts, existing) do
    reason = facts["reason"]

    case existing do
      [%{facts: %{"reason" => ^reason}} = request] ->
        if facts["target"] == "planning",
          do: Sessions.signal(key, params["session"], :waiting)

        {:ok, request}

      _ ->
        Enum.each(
          existing,
          &Requests.resolve(&1.id, :facts_changed, %{"reason" => "waiting_changed"})
        )

        with {:ok, request} <-
               Requests.create(key, "session_waiting", Map.put(params, "facts", facts)) do
          if facts["target"] == "planning",
            do: Sessions.signal(key, params["session"], :waiting)

          {:ok, request}
        end
    end
  end

  @doc "UI-only action; no agent command exposes this boundary."
  def continue(id) do
    transaction(fn ->
      case Requests.get(id) do
        nil ->
          {:error, :not_found}

        request ->
          lock(request.repo_key)
          request = Requests.get(id)

          state = Enum.find(Foreman.Request.__fsm__(:states), &(to_string(&1) == request.state))
          context = %{kind: request.kind, reason: request.facts["reason"]}

          with {:pending, [send: :continue]} <- Foreman.Request.step(state, :continue, context) do
            result =
              case request.facts["target"] do
                "planning" ->
                  case Sessions.get({request.repo_key, request.bead_id}) do
                    %PlanningSession{session_id: session_id, state: :waiting, window: window} = s
                    when session_id == request.session ->
                      if window == request.facts["window"],
                        do: SessionTmux.continue_session(s),
                        else: {:error, :invalid_window}

                    _ ->
                      {:error, :invalid_window}
                  end

                "external" ->
                  SessionTmux.continue_external(request.facts)

                _ ->
                  {:error, :invalid_window}
              end

            case result do
              :ok -> {:ok, request}
              error -> error
            end
          else
            _ -> {:error, :invalid}
          end
      end
    end)
  end

  def reconcile_external do
    Repo.all(from r in Request, where: r.kind == "session_waiting" and r.state == "pending")
    |> Enum.filter(&(&1.facts["target"] == "external"))
    |> Enum.each(fn request ->
      transaction(fn ->
        lock(request.repo_key)

        case SessionTmux.external_target(request.facts["window"]) do
          {:ok, facts} ->
            if Map.take(facts, ~w(pane pid snapshot)) !=
                 Map.take(request.facts, ~w(pane pid snapshot)),
               do: Requests.resolve(request.id, :facts_changed, %{"reason" => "session_resumed"})

          _ ->
            Requests.resolve(request.id, :facts_changed, %{"reason" => "window_gone"})
        end
      end)
    end)

    :ok
  end

  def clear(key, session) do
    for request <- pending(key, session),
        do: Requests.resolve(request.id, :facts_changed, %{"reason" => "session_resumed"})

    :ok
  end

  def pending({project, ticket}, session),
    do:
      Repo.all(
        from r in Request,
          where:
            r.repo_key == ^project and r.bead_id == ^ticket and r.session == ^session and
              r.kind == "session_waiting" and r.state == "pending"
      )

  defp turn_ended?(facts),
    do: facts["target"] == "planning" and facts["reason"] == "input" and is_nil(facts["tool"])

  defp target(key, id, facts, original) do
    case Sessions.get(key) do
      %PlanningSession{session_id: ^id, state: state, window: window} = s
      when state in [:starting, :running, :waiting] and not is_nil(window) ->
        {:ok,
         Map.merge(facts, %{
           "target" => "planning",
           "session_id" => id,
           "window" => window,
           "attach" => SessionTmux.attach_command(s)
         })}

      _ when key == {"__foreman__", "coordinator"} ->
        {:error, :unknown_session}

      _ ->
        if match?({:ok, _}, Ecto.UUID.cast(id)) and not is_nil(Repo.get(PlanningSession, id)) do
          {:error, :unknown_session}
        else
          with {:ok, target} <- SessionTmux.external_target(original["window"]) do
            {:ok, Map.merge(facts, target)}
          end
        end
    end
  end

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
