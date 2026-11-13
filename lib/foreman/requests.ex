defmodule Foreman.Requests do
  @moduledoc "Durable asks, serialized with ticket lifecycle changes. Only kind modules may enqueue approval jobs."
  import Ecto.Query
  alias Foreman.{Repo, Overlay}
  alias Foreman.Requests.{Request, Kind, Decision}
  alias Foreman.Request, as: Machine

  def ask(key, "session_waiting", params), do: Foreman.SessionWaiting.ask(key, params)
  def ask(key, kind, params), do: create(key, kind, params)

  @doc false
  def create({repo, _} = key, kind, params) when is_map(params) do
    transaction(fn ->
      lock(repo)

      with {:ok, handler} <- Kind.fetch(kind),
           row when not is_nil(row) <- request_subject(key, kind),
           true <- row.stage not in [:done, :abandoned],
           true <- Decision.text?(params["actor"] || "user"),
           true <- is_nil(params["session"]) or Decision.text?(params["session"]),
           {:ok, facts} <- handler.validate(params["facts"], row),
           {:ok, standing} <- standing_answer(repo, kind, facts),
           {:ok, id} <- Ecto.UUID.cast(params["request_id"] || Ecto.UUID.generate()),
           nil <- pending_chore(repo, kind, facts) do
        {:pending, effects} = Machine.step(:new, :ask, %{kind: kind})

        # The asking session is fixed now, never at render (Decision 5).
        agent_session_id =
          case Foreman.AgentSessions.resolve_asker(params) do
            {:ok, session} -> Foreman.AgentSessions.card_owner(session, kind, facts, key).id
            {:unknown, _} -> nil
          end

        request =
          Repo.insert!(%Request{
            id: id,
            repo_key: repo,
            bead_id: row.bead_id,
            kind: kind,
            actor: params["actor"] || "user",
            session: params["session"],
            agent_session_id: agent_session_id,
            facts:
              if(kind == "review_ui" and facts["url"],
                do: Map.put(facts, "preview", "unchecked"),
                else: facts
              ),
            state: "pending"
          })

        audit(request, :new, :ask, %{}, effects)
        Foreman.AgentSessions.card_opened(request)
        notify(request)
        {:ok, %{request | standing_answer: standing}}
      else
        %Request{} = existing -> {:ok, existing}
        nil -> {:error, :not_found}
        false -> {:error, :ticket_finished}
        :error -> {:error, :invalid_request_id}
        error -> error
      end
    end)
  end

  defp pending_chore(_repo, "chore", %{"key" => key}) when is_binary(key) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["foreman:chore:" <> key])

    Repo.one(
      from r in Request,
        where:
          r.kind == "chore" and r.state == "pending" and
            fragment("?->>'key'", r.facts) == ^key,
        limit: 1
    )
  end

  defp pending_chore(_, _, _), do: nil

  defp standing_answer(repo, "decision", facts) do
    case Foreman.Answers.standing_match(repo, facts) do
      {:exact, answer} -> {:error, %{error: "already_answered", standing_answer: answer}}
      {:close, answer} -> {:ok, answer}
      :none -> {:ok, nil}
    end
  end

  defp standing_answer(_, _, _), do: {:ok, nil}

  # The singleton coordinator has no ticket overlay. Only session attention may
  # use this system identity; approvals still require an actual ticket.
  defp request_subject({"__foreman__", "coordinator"}, "session_waiting"),
    do: %{stage: :building, bead_id: "coordinator"}

  defp request_subject(key, _kind), do: Overlay.get(key)

  def withdraw(id, actor, session, reason) do
    case get(id) do
      nil -> {:error, :not_found}
      %{actor: ^actor, session: ^session} -> resolve(id, :withdraw, %{"reason" => reason})
      _ -> {:error, :forbidden}
    end
  end

  def update(id, actor, session, changes) when is_map(changes) do
    transaction(fn ->
      case get(id) do
        nil ->
          {:error, :not_found}

        request ->
          lock(request.repo_key)
          request = get(id)

          cond do
            request.actor != actor or request.session != session ->
              {:error, :forbidden}

            request.state != "pending" ->
              {:error, %{error: "not_pending", state: request.state}}

            true ->
              with {:ok, facts} <- updated_facts(request, changes),
                   {:pending, effects} <- Machine.step(:pending, :update, context(request)) do
                updated =
                  request
                  |> Ecto.Changeset.change(facts: facts, edited_at: DateTime.utc_now())
                  |> Repo.update!()

                audit(updated, :pending, :update, changes, effects)
                notify(updated)
                {:ok, updated}
              end
          end
      end
    end)
  end

  def update(_, _, _, _), do: {:error, :invalid_facts}

  defp updated_facts(request, changes) do
    allowed =
      if request.kind == "decision",
        do: ~w(question text options option_details recommendation docs),
        else: ~w(question text docs)

    if Enum.all?(Map.keys(changes), &(&1 in allowed)) do
      facts = Map.merge(request.facts, changes)

      facts =
        if Map.has_key?(changes, "options") do
          facts
          |> Map.put("option_details", Map.get(changes, "option_details", %{}))
          |> Map.put("recommendation", Map.get(changes, "recommendation"))
        else
          facts
        end

      with {:ok, validated} <- validate_update(request, Map.delete(facts, "docs")),
           {:ok, docs} <- update_docs(request, changes) do
        {:ok, Map.put(validated, "docs", docs)}
      end
    else
      {:error, :invalid_facts}
    end
  end

  defp validate_update(%{kind: kind} = request, facts)
       when kind in ["decision", "review_ui", "chore", "batch"] do
    {:ok, handler} = Kind.fetch(kind)
    handler.validate(facts, %{repo_key: request.repo_key})
  end

  defp validate_update(_, facts) do
    if Enum.all?(
         ["question", "text"],
         &(not Map.has_key?(facts, &1) or Decision.text?(facts[&1]))
       ),
       do: {:ok, facts},
       else: {:error, :invalid_facts}
  end

  defp update_docs(request, %{"docs" => docs}),
    do: Foreman.CardText.docs(docs, request.repo_key)

  defp update_docs(request, _), do: {:ok, Map.get(request.facts, "docs", [])}

  def withdrawable?(request), do: request.actor in ~w(pi claude codex agent coordinator)

  def withdraw_from_card(id, reason) do
    case get(id) do
      nil ->
        {:error, :not_found}

      request ->
        if withdrawable?(request),
          do: withdraw(id, request.actor, request.session, reason),
          else: {:error, :forbidden}
    end
  end

  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(Request, id)
      _ -> nil
    end
  end

  def reconcile_open_prs do
    Repo.all(
      from r in Request, where: r.kind == "open_pr" and r.state in ["pending", "executing"]
    )
    |> Enum.each(fn request ->
      if request.state == "pending" do
        case Foreman.Requests.OpenPr.unchanged(
               request.facts,
               Foreman.Forge.adapter(),
               Foreman.Forge.options()
             ) do
          {:error, reason} when reason in [:head_moved, :head_missing] ->
            resolve(request.id, :facts_changed, %{"reason" => to_string(reason)})

          _ ->
            :ok
        end
      else
        active =
          Repo.exists?(
            from j in Oban.Job,
              where:
                j.worker == "Foreman.Requests.OpenPrJob" and
                  fragment("?->>'request_id'", j.args) == ^request.id and
                  j.state in ["available", "scheduled", "executing", "retryable"]
          )

        if not active or DateTime.diff(DateTime.utc_now(), request.updated_at) > 90,
          do: resolve(request.id, :orphaned, %{})
      end
    end)

    :ok
  end

  def reconcile_pushes do
    requests =
      Repo.all(from r in Request, where: r.kind == "push" and r.state in ["pending", "executing"])

    Enum.each(requests, fn request ->
      cond do
        request.state == "pending" and Foreman.Requests.Push.unchanged(request.facts) != :ok ->
          resolve(request.id, :facts_changed, %{"reason" => "local_sha_changed"})

        request.state == "executing" ->
          active =
            Repo.exists?(
              from j in Oban.Job,
                where:
                  j.worker == "Foreman.Requests.PushJob" and
                    fragment("?->>'request_id'", j.args) == ^request.id and
                    j.state in ["available", "scheduled", "executing", "retryable"]
            )

          if not active or DateTime.diff(DateTime.utc_now(), request.updated_at) > 90,
            do: resolve(request.id, :orphaned, %{})

        true ->
          :ok
      end
    end)

    :ok
  end

  def pending_count, do: Repo.aggregate(from(r in Request, where: r.state == "pending"), :count)

  @doc "Pending requests by their ticket's priority (missing last), then oldest first."
  def pending do
    from(r in Request, where: r.state == "pending", order_by: [r.inserted_at, r.id])
    |> Repo.all()
    |> with_priority()
    |> Foreman.Requests.Questions.flag()
    |> Enum.sort_by(&Foreman.Priority.rank(&1.priority))
  end

  @doc "Fills each request's ticket priority. Epic requests may name the draft slug."
  def with_priority(requests) do
    aliases =
      Repo.all(
        from e in "epics",
          where: not is_nil(e.beads_epic_id),
          select: {{e.repo_key, e.bead_id}, {e.repo_key, e.beads_epic_id}}
      )
      |> Map.new()

    target = fn r -> Map.get(aliases, {r.repo_key, r.bead_id}, {r.repo_key, r.bead_id}) end
    priorities = requests |> Enum.map(target) |> Foreman.Priority.for_keys()

    Enum.map(requests, fn r ->
      %{r | priority: get_in(priorities, [target.(r), :priority])}
    end)
  end

  def recent,
    do:
      Repo.all(
        from r in Request,
          where: r.state not in ["pending", "approved", "executing"],
          order_by: [desc: r.updated_at, desc: r.id],
          limit: 50
      )

  def for_ticket({repo, id}) do
    row = Overlay.get({repo, id})

    ids =
      case row do
        %{machine: Foreman.Epic} -> Enum.reject([row.bead_id, row.beads_epic_id], &is_nil/1)
        _ -> [id]
      end

    Repo.all(
      from r in Request,
        where: r.repo_key == ^repo and r.bead_id in ^ids,
        order_by: [desc: r.inserted_at, desc: r.id]
    )
  end

  @doc "Internal interpreter. HTTP agents cannot submit worker or observed events."
  def resolve(id, event, payload) when is_map(payload) do
    transaction(fn ->
      case get(id) do
        nil ->
          {:error, :not_found}

        request ->
          lock(request.repo_key)
          request = Repo.get!(Request, id)

          changed = approval_change(request, event)

          cond do
            changed ->
              transition(request, :facts_changed, %{"reason" => changed})

            event == :approve and request.kind == "merge" and request.state == "pending" ->
              case Foreman.Requests.Merge.unchanged(request.repo_key, request.facts) do
                :ok ->
                  with :ok <- validate(:approve, payload) do
                    if Map.has_key?(payload, "note") do
                      request |> Ecto.Changeset.change(note: payload["note"]) |> Repo.update!()
                    end

                    {:error, :confirmation_required}
                  end

                {:error, reason} ->
                  transition(request, :facts_changed, %{"reason" => to_string(reason)})
              end

            true ->
              transition(request, event, payload)
          end
      end
    end)
  end

  defp approval_change(%{kind: "push", state: "pending"} = request, :approve) do
    if Foreman.Requests.Push.unchanged(request.facts) != :ok, do: "local_sha_changed"
  end

  defp approval_change(%{kind: "open_pr", state: "pending"} = request, :approve) do
    case Foreman.Requests.OpenPr.observed_head(request.repo_key, request.facts) do
      {:error, reason} when reason in [:head_moved, :head_missing] -> to_string(reason)
      _ -> nil
    end
  end

  defp approval_change(_, _), do: nil

  @doc "Final modal confirmation: request approval, existing merge intent and linkage commit together."
  def confirm_merge(id, facts, note \\ nil) do
    transaction(fn ->
      case get(id) do
        %{kind: "merge"} = request ->
          lock(request.repo_key)
          request = get(id)

          cond do
            request.state != "pending" ->
              {:error, :invalid}

            facts["pr"]["number"] != request.facts["number"] or
                facts["pr"]["head_sha"] != request.facts["expected_sha"] ->
              {:error, :invalid}

            true ->
              case Foreman.Requests.Merge.unchanged(request.repo_key, request.facts) do
                :ok ->
                  with {:ok, approved} <- transition(request, :approve, %{"note" => note}),
                       {:ok, action} <-
                         Foreman.Merge.enqueue(request.repo_key, request.facts["remote"], facts),
                       {:ok, executing} <-
                         transition(approved, :start, %{"result" => %{"action_id" => action.id}}) do
                    {:ok, executing}
                  else
                    {:error, reason} -> Repo.rollback(reason)
                  end

                {:error, reason} ->
                  transition(request, :facts_changed, %{"reason" => to_string(reason)})
              end
          end

        _ ->
          {:error, :invalid}
      end
    end)
  end

  @doc "Observe existing merge audits; never perform or retry a forge write."
  def reconcile_merges do
    Repo.all(from r in Request, where: r.kind == "merge" and r.state in ["pending", "executing"])
    |> Enum.each(fn request ->
      if request.state == "pending" do
        # Recheck under the request lock rather than superseding from a stale read.
        resolve(request.id, :approve, %{})
      else
        action =
          request.outcome["result"]["action_id"]
          |> Foreman.Merge.get()
          |> Foreman.Merge.reconcile()

        if action && (not is_nil(action.merge_sha) or action.state == "failed") do
          result = %{
            "action_id" => action.id,
            "merge_sha" => action.merge_sha,
            "state" => action.state
          }

          event = if action.merge_sha, do: :succeeded, else: :failed
          reason = if event == :failed, do: action.error
          resolve(request.id, event, %{"result" => result, "reason" => reason})
        end
      end
    end)

    :ok
  end

  def supersede(key) do
    for request <- for_ticket(key),
        request.state == "pending",
        request.kind in ["push", "open_pr", "merge"] do
      transition(request, :facts_changed, %{"reason" => "ticket_finished"})
    end

    :ok
  end

  defp transition(request, event, payload) do
    state = Enum.find(Machine.__fsm__(:states), &(to_string(&1) == request.state))

    with {:ok, payload} <- answer_payload(request, event, payload),
         :ok <- validate_payload(request, event, payload),
         {next, effects} when next != :error <- Machine.step(state, event, context(request)) do
      if next == state do
        {:ok, request}
      else
        outcome =
          case event do
            :answer -> Map.take(payload, ["answer"])
            :orphaned -> %{"reason" => "outcome unknown"}
            _ -> Map.take(payload, ["reason", "result"])
          end

        request =
          request
          |> Ecto.Changeset.change(
            state: to_string(next),
            facts:
              if(request.kind == "review_ui",
                do: Foreman.PreviewCheck.stop(request.facts),
                else: request.facts
              ),
            outcome: outcome,
            note: Map.get(payload, "note", request.note)
          )
          |> Repo.update!()

        if request.kind == "decision" and event == :answer and payload["always"] == true,
          do: Foreman.Answers.remember(request)

        audit(request, state, event, payload, effects)
        if state == :pending, do: Foreman.AgentSessions.card_closed(request)

        # R9: an answer to an ended session resumes it or goes to its coordinator, in this
        # transaction; when it cannot be delivered the card stays open.
        if event == :answer and state == :pending do
          case Foreman.SessionResume.deliver_answer(request, payload, answer_opts()) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end

        if {:enqueue, :job} in effects do
          with {:ok, handler} <- Kind.fetch(request.kind), :ok <- handler.enqueue(request) do
            :ok
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end

        notify(request)
        {:ok, request}
      end
    else
      {:error, _} -> {:error, :invalid}
    end
  end

  # Tests and the preview point the answer's tmux and launchers at stand-ins.
  defp answer_opts, do: Application.get_env(:foreman, :session_controls_tmux, [])

  defp answer_payload(%{kind: "review_ui"} = request, :answer, payload),
    do: Foreman.Requests.ReviewUI.answer(request, payload)

  defp answer_payload(%{kind: "batch"} = request, :answer, payload),
    do: Foreman.Requests.Batch.answer(request, payload)

  defp answer_payload(_, _, payload), do: {:ok, payload}

  @doc false
  def context(request),
    do: %{
      kind: request.kind,
      reason: request.facts["reason"],
      questions: request.facts["questions"]
    }

  defp validate_payload(%{kind: "batch"}, :answer, payload), do: validate(:batch_answer, payload)
  defp validate_payload(_, event, payload), do: validate(event, payload)

  defp validate(:wrong_question, payload) do
    if Decision.text?(payload["note"]), do: :ok, else: {:error, :reason_required}
  end

  defp validate(:withdraw, payload) do
    if Decision.text?(payload["reason"]), do: :ok, else: {:error, :reason_required}
  end

  defp validate(:answer, payload) do
    if Decision.text?(payload["answer"]), do: :ok, else: {:error, :answer_required}
  end

  defp validate(_, payload) do
    if is_nil(payload["note"]) or
         (is_binary(payload["note"]) and byte_size(payload["note"]) <= 20_000),
       do: :ok,
       else: {:error, :invalid_note}
  end

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock(repo),
    do:
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "foreman:overlay:" <> repo
      ])

  defp notify(request), do: Foreman.Events.broadcast(:requests_changed, request.id)

  defp audit(request, from, event, payload, effects) do
    Repo.insert_all("request_events", [
      %{
        request_id: Ecto.UUID.dump!(request.id),
        event: to_string(event),
        from_state: to_string(from),
        to_state: request.state,
        payload: payload,
        effects: %{items: Enum.map(effects, fn {k, v} -> %{kind: k, name: v} end)},
        inserted_at: DateTime.utc_now()
      }
    ])
  end
end
