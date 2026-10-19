defmodule Foreman.Sessions do
  @moduledoc "Board-owned planning sessions, separate from dispatched build sessions."
  import Ecto.Query
  alias Foreman.{Repo, PlanningSession, SessionMachine, SessionTmux}

  @coordinator_key {"__foreman__", "coordinator"}
  def coordinator_key, do: @coordinator_key
  def coordinator, do: get(@coordinator_key)
  def coordinator?(session), do: {session.project, session.ticket} == @coordinator_key

  def prepare_coordinator(mode, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write(),
         true <- mode in [:resume, :fresh] or match?({:adopt, _}, mode),
         {:ok, adopted} <- coordinator_id(mode) do
      {:ok, result} =
        Repo.transaction(fn ->
          Foreman.SessionWaiting.lock(elem(@coordinator_key, 0))
          current = coordinator()

          current =
            case current do
              nil -> nil
              %{window: nil} -> transition(current, :window_gone)
              _ -> observe(current, opts)
            end

          event =
            case mode do
              :resume -> :coordinator_resume
              :fresh -> :coordinator_fresh
              {:adopt, _} -> :adopt
            end

          previous_state = if current, do: current.state, else: :new

          case SessionMachine.step(previous_state, event, %{coordinator: true}) do
            {:error, _} ->
              {:error, :coordinator_active}

            {state, effects} ->
              identity = Keyword.fetch!(effects, :identity)

              id =
                case identity do
                  :keep -> current.session_id
                  :new -> Ecto.UUID.generate()
                  :adopt -> adopted
                end

              if current && identity != :keep,
                do: Foreman.SessionWaiting.clear(@coordinator_key, current.session_id)

              attrs = %{
                session_id: id,
                state: state,
                window: opts[:window],
                error: nil,
                workdir:
                  Keyword.get(
                    opts,
                    :workdir,
                    Application.get_env(
                      :foreman,
                      :coordinator_workdir,
                      Path.expand("~/dev/music")
                    )
                  ),
                launched_at: DateTime.utc_now(),
                last_activity_at: DateTime.utc_now(),
                previous_windows: []
              }

              session =
                if current do
                  save(current, attrs)
                else
                  struct(
                    PlanningSession,
                    Map.merge(attrs, %{
                      project: elem(@coordinator_key, 0),
                      ticket: elem(@coordinator_key, 1)
                    })
                  )
                  |> Repo.insert!()
                end

              launch = %{new: :fresh, keep: :resume, adopt: :adopt}[identity]
              {:ok, session, launch}
          end
        end)

      Foreman.Events.broadcast(:sessions_changed, elem(@coordinator_key, 0))
      result
    else
      false -> {:error, :invalid_coordinator_mode}
      error -> error
    end
  end

  def launch_coordinator(mode \\ :resume, opts \\ []) do
    coordinator_transaction(fn ->
      with {:ok, session, launch} <- prepare_coordinator(mode, opts) do
        result =
          if launch == :fresh,
            do: SessionTmux.launch(session, "/orient", opts),
            else: SessionTmux.resume(session, opts)

        case result do
          {:ok, window} ->
            session = save(session, %{window: window})
            Foreman.Events.broadcast(:sessions_changed, session.project)
            {:ok, session}

          {:error, reason} ->
            save(session, %{error: error_message(reason)})
            {:error, reason}
        end
      end
    end)
  end

  def coordinator_command(%{"mode" => "adopt", "adopt" => id}) do
    with {:ok, session, :adopt} <- prepare_coordinator({:adopt, id}),
         do: {:ok, %{session_id: session.session_id}}
  end

  def coordinator_command(%{"mode" => mode} = request) when mode in ["resume", "fresh"] do
    coordinator_transaction(fn ->
      with {:ok, window} <- SessionTmux.coordinator_pane(request),
           {:ok, session, launch} <-
             prepare_coordinator(if(mode == "fresh", do: :fresh, else: :resume), window: window),
           :ok <- SessionTmux.respawn_coordinator(session, launch, request["pane"]) do
        {:ok, %{session_id: session.session_id}}
      end
    end)
  end

  def coordinator_command(_), do: {:error, :invalid_coordinator_mode}

  defp coordinator_transaction(fun) do
    Repo.transaction(fn ->
      Foreman.SessionWaiting.lock(elem(@coordinator_key, 0))

      case fun.() do
        {:error, reason} -> Repo.rollback(reason)
        result -> result
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp coordinator_id({:adopt, id}) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        case Repo.get(PlanningSession, id) do
          nil -> {:ok, id}
          session -> if coordinator?(session), do: {:ok, id}, else: {:error, :session_id_in_use}
        end

      :error ->
        {:error, :invalid_session_id}
    end
  end

  defp coordinator_id(_), do: {:ok, nil}

  def launchable?(%{type: "epic", stage: stage}), do: stage in [:idea, :draft]

  def launchable?(%{type: type, status: status, parent: nil}) when is_binary(type),
    do: type != "epic" and status not in ["closed", "tombstone"]

  def launchable?(_), do: false

  def target(key) do
    snapshot = Foreman.Initiatives.snapshot(%{"view" => ""})
    orphan = Enum.find(snapshot.orphans, &(&1.key == key))
    epic = find_epic(snapshot.drafts ++ snapshot.epics, key)

    cond do
      orphan -> Map.put(orphan, :parent, Enum.find(orphan.edges, &(&1.type == "parent-child")))
      epic -> epic
      true -> nil
    end
  end

  def get({project, ticket}), do: Repo.get_by(PlanningSession, project: project, ticket: ticket)

  def launch({project, ticket} = key, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write(),
         target when not is_nil(target) <- target(key),
         true <- launchable?(target),
         repo when not is_nil(repo) <-
           Enum.find(Foreman.RuntimeState.repos(), &(&1["key"] == project)),
         {:ok, workdir} <- main_checkout(repo["path"]),
         prompt when is_binary(prompt) <- opening_prompt(target, project, ticket) do
      {state, [open: :window]} = SessionMachine.step(:new, :launch, %{})
      # Reserve identity before external IO. A crash can retry with this UUID;
      # tmux's exact-name lookup recovers a window created before a DB update.
      Repo.insert!(
        %PlanningSession{
          project: project,
          ticket: ticket,
          workdir: workdir,
          state: state,
          launched_at: DateTime.utc_now()
        },
        on_conflict: :nothing,
        conflict_target: [:project, :ticket]
      )

      {:ok, result} =
        Repo.transaction(fn ->
          Foreman.SessionWaiting.lock(project)
          session = locked(key) |> observe(opts)

          if session.state == :parked do
            {:error, :session_parked}
          else
            case SessionTmux.launch(session, prompt, opts) do
              {:ok, window} ->
                session = save(session, %{window: window, error: nil}) |> observe(opts)
                {:ok, session}

              {:error, reason} ->
                save(session, %{error: error_message(reason)})
                {:error, reason}
            end
          end
        end)

      Foreman.Events.broadcast(:sessions_changed, project)
      result
    else
      false -> {:error, :not_launchable}
      nil -> {:error, :not_launchable}
      error -> error
    end
  end

  def relaunch({project, _} = key, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write() do
      {:ok, result} =
        Repo.transaction(fn ->
          Foreman.SessionWaiting.lock(project)

          case get(key) do
            nil ->
              {:error, :not_relaunchable}

            _ ->
              session = locked(key) |> observe(opts)

              case SessionMachine.step(session.state, :relaunch, %{}) do
                {:starting, [open: :resume]} ->
                  case SessionTmux.resume(session, opts) do
                    {:ok, window} ->
                      previous =
                        if session.state == :ended do
                          session.previous_windows ++
                            [
                              %{
                                "window" => session.window,
                                "last_activity_at" =>
                                  DateTime.to_iso8601(
                                    session.last_activity_at || session.launched_at
                                  )
                              }
                            ]
                        else
                          session.previous_windows
                        end

                      session = transition(session, :relaunch)

                      {:ok,
                       save(session, %{
                         window: window,
                         previous_windows: previous,
                         error: nil,
                         last_activity_at: DateTime.utc_now()
                       })}

                    {:error, reason} ->
                      save(session, %{error: error_message(reason)})
                      {:error, reason}
                  end

                _ ->
                  {:error, :not_relaunchable}
              end
          end
        end)

      Foreman.Events.broadcast(:sessions_changed, project)
      result
    end
  end

  def signal({project, _} = key, id, event, tool \\ nil)
      when event in [:waiting, :resumed, :activity] do
    Repo.transaction(fn ->
      Foreman.SessionWaiting.lock(project)

      case get(key) do
        %PlanningSession{session_id: ^id} ->
          session = locked(key)
          pending = Foreman.SessionWaiting.pending(key, id)

          session = save(session, %{last_activity_at: DateTime.utc_now()})
          {:ok, transition(session, event, %{resume_matches: resumes?(pending, tool)})}

        _ ->
          {:error, :unknown_session}
      end
    end)
    |> case do
      {:ok, result} -> result
      error -> error
    end
  end

  defp resumes?(_pending, nil), do: true
  defp resumes?([], _tool), do: true

  defp resumes?(pending, tool),
    do:
      Enum.any?(pending, fn request ->
        request.facts["tool"] == tool or
          (tool == "activity" and is_nil(request.facts["tool"]) and
             request.facts["reason"] in ["input", "usage_limit"])
      end)

  def reconcile(opts \\ []) do
    Foreman.SessionWaiting.reconcile_external()

    Repo.all(from s in PlanningSession, where: s.state != :parked or s.previous_windows != [])
    |> Enum.each(fn s ->
      Repo.transaction(fn ->
        Foreman.SessionWaiting.lock(s.project)

        locked({s.project, s.ticket})
        |> observe(opts)
        |> park_if_idle(opts)
        |> reconcile_previous(opts)
      end)
    end)

    :ok
  end

  defp reconcile_previous(session, opts) do
    previous =
      Enum.flat_map(session.previous_windows, fn entry ->
        {:ok, last, _} = DateTime.from_iso8601(entry["last_activity_at"])
        old = %{session | window: entry["window"], state: :ended, last_activity_at: last}

        case SessionTmux.observe(old, opts) do
          {:ok, :window_gone} ->
            []

          {:ok, _} ->
            case idle_result(old, opts) do
              :parked -> []
              {:active, now} -> [Map.put(entry, "last_activity_at", DateTime.to_iso8601(now))]
              :unchanged -> [entry]
            end

          _ ->
            [entry]
        end
      end)

    if previous == session.previous_windows,
      do: session,
      else: save(session, %{previous_windows: previous})
  end

  defp park_if_idle(%{state: state} = session, opts) when state in [:running, :waiting, :ended] do
    case idle_result(session, opts) do
      :parked -> transition(session, :idle_timeout)
      {:active, now} -> save(session, %{last_activity_at: now})
      :unchanged -> session
    end
  end

  defp park_if_idle(session, _opts), do: session

  defp idle_result(session, opts) do
    now = DateTime.utc_now()

    timeout =
      Keyword.get(
        opts,
        :idle_timeout,
        Application.get_env(:foreman, :planning_idle_timeout, 86_400)
      )

    case SessionTmux.attached?(session, opts) do
      {:ok, true} ->
        {:active, now}

      {:ok, false} ->
        last = session.last_activity_at || session.launched_at

        if DateTime.diff(now, last, :second) >= timeout do
          {_state, effects} =
            SessionMachine.step(session.state, :idle_timeout, %{
              coordinator: coordinator?(session)
            })

          if {:close, :window} in effects and SessionTmux.park(session, opts) == :ok,
            do: :parked,
            else: :unchanged
        else
          :unchanged
        end

      _ ->
        :unchanged
    end
  end

  defp observe(session, opts) do
    case SessionTmux.observe(session, opts) do
      {:ok, :window_gone} when not is_nil(session.window) ->
        transition(session, :window_gone)

      {:ok, %{window: window, state: state}} ->
        session = save(session, %{window: window})
        session = if state in [:running, :ended], do: transition(session, :started), else: session
        if state == :ended, do: transition(session, :exited), else: session

      _ ->
        session
    end
  end

  defp transition(session, event, context \\ %{}) do
    {state, effects} =
      SessionMachine.step(
        session.state,
        event,
        Map.put(context, :coordinator, coordinator?(session))
      )

    if {:clear, :waiting} in effects,
      do: Foreman.SessionWaiting.clear({session.project, session.ticket}, session.session_id)

    if state != session.state do
      result = save(session, %{state: state, observed_at: DateTime.utc_now()})

      Foreman.Events.broadcast(:sessions_changed, session.project)
      result
    else
      session
    end
  end

  defp locked({project, ticket}),
    do:
      Repo.one!(
        from s in PlanningSession,
          where: s.project == ^project and s.ticket == ^ticket,
          lock: "FOR UPDATE"
      )

  defp save(session, attrs), do: session |> Ecto.Changeset.change(attrs) |> Repo.update!()

  defp find_epic(epics, key),
    do:
      Enum.find_value(epics, fn epic ->
        if epic.key == key, do: epic, else: find_epic(Map.get(epic, :children, []), key)
      end)

  defp opening_prompt(target, project, ticket) do
    source =
      if String.starts_with?(ticket, "draft:"),
        do:
          "the board draft #{ticket}" <>
            if(target.spec_link, do: " and #{target.spec_link}", else: ""),
        else: "tickets/#{ticket}.md"

    Foreman.SessionPrompt.render(target.type, %{ticket: ticket, project: project, source: source})
  end

  defp main_checkout(path) do
    case System.cmd("git", ["-C", path, "worktree", "list", "--porcelain"],
           stderr_to_stdout: true
         ) do
      {"worktree " <> output, 0} -> {:ok, output |> String.split("\n", parts: 2) |> hd()}
      _ -> {:error, :main_checkout_unavailable}
    end
  rescue
    ErlangError -> {:error, :main_checkout_unavailable}
  end

  def error_message(:coordinator_active), do: "Coordinator is still running; focus its window"
  def error_message("refused in preview"), do: "refused in preview"
  def error_message(:not_launchable), do: "Ticket cannot be launched"
  def error_message(:session_parked), do: "Session window is gone"
  def error_message(:main_checkout_unavailable), do: "Main checkout unavailable"
  def error_message(:claude_unavailable), do: "Claude unavailable; check the web service PATH"
  def error_message(:prompt_unavailable), do: "Install the foreman skill session-launch templates"
  def error_message(_), do: "Launch failed; check tmux and retry"
end
