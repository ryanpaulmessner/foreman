defmodule Foreman.SessionModelResume do
  @moduledoc "Resumes a usage-limited conversation on its configured alternative, preserving handled partial failures."
  import Ecto.Query

  alias Foreman.{
    AgentSession,
    AgentSessions,
    Repo,
    SessionCaptures,
    SessionFallback,
    SessionLaunch,
    SessionPane,
    SessionProcess
  }

  def resume(row, opts \\ []) do
    with :ok <- Foreman.Preview.allow_external_write() do
      case Repo.transaction(fn -> locked_resume(row, opts) end) do
        {:ok, {:opened, row}} -> activate(row, opts)
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp locked_resume(row, opts) do
    AgentSessions.lock(row.name)
    row = Repo.one(from s in AgentSession, where: s.id == ^row.id, lock: "FOR UPDATE")

    with %AgentSession{} <- row,
         model when is_binary(model) <- SessionFallback.model(row),
         true <- AgentSessions.resumable?(row),
         {:ok, _} <- SessionLaunch.executable(row.harness, opts),
         {:ok, pane} <- SessionPane.resolve(row, opts),
         {:ok, process} <- SessionProcess.record(row, pane, opts),
         {:ok, _} <-
           SessionCaptures.capture(
             row,
             :stop,
             Keyword.put(opts, :target, %{socket: pane.socket, target: pane.pane})
           ),
         {:ok, row, _} <- AgentSessions.fire(row, :resume_on_model) do
      planning_step(row, :resume_on_model)

      case SessionProcess.stop(process, opts) do
        :ok -> open(row, model, opts)
        {:error, reason} -> failed(row, {:stop_unconfirmed, reason})
      end
    else
      {:error, reason} -> Repo.rollback(reason)
      _ -> Repo.rollback(:invalid)
    end
  end

  defp open(row, model, opts) do
    candidate = %{row | model: model}
    opts = Keyword.put(opts, :model_resume, true)

    opts =
      if row.harness == "claude",
        do: Keyword.put(opts, :prompt, "continue"),
        else: Keyword.delete(opts, :prompt)

    case SessionLaunch.resume(candidate, opts) do
      {:ok, pane} ->
        opened(row, model, pane, opts)

      {:error, {:opened, pane, reason}} ->
        row
        |> Ecto.Changeset.change(model: model)
        |> Repo.update!()
        |> AgentSessions.opened_pane(pane)

        {:error, {:model_resume_partial, :opened, reason}}

      {:error, reason} ->
        failed(row, {:stopped, reason})
    end
  end

  defp opened(row, model, pane, opts) do
    row =
      row
      |> Ecto.Changeset.change(model: model)
      |> Repo.update!()
      |> AgentSessions.opened_pane(pane)

    with :ok <- planning_opened(row, opts) do
      {:opened, row}
    else
      {:error, reason} -> {:error, {:model_resume_partial, :opened, reason}}
    end
  end

  defp activate(row, opts) do
    with :ok <- SessionLaunch.activate_model(row, opts) do
      for card <- AgentSessions.open_cards(row.id),
          card.kind == "session_waiting" and card.facts["reason"] == "usage_limit" do
        Foreman.Requests.resolve(card.id, :facts_changed, %{"reason" => "resumed_on_model"})
      end

      {:ok, row}
    else
      {:error, reason} -> {:error, {:model_resume_partial, :opened, reason}}
    end
  end

  defp planning_step(row, event) do
    if planning = Repo.get(Foreman.PlanningSession, row.id) do
      {state, _} = Foreman.SessionMachine.step(planning.state, event, %{})
      planning |> Ecto.Changeset.change(state: state) |> Repo.update!()
    end
  end

  defp planning_opened(row, opts) do
    case Repo.get(Foreman.PlanningSession, row.id) do
      nil ->
        :ok

      planning ->
        with {:ok, window} <- SessionLaunch.window(row, opts) do
          planning
          |> Ecto.Changeset.change(
            window: window,
            last_activity_at: DateTime.utc_now(),
            observed_at: nil,
            previous_windows:
              planning.previous_windows ++
                [
                  %{
                    "window" => planning.window,
                    "last_activity_at" =>
                      DateTime.to_iso8601(
                        planning.last_activity_at || planning.launched_at || DateTime.utc_now()
                      )
                  }
                ]
          )
          |> Repo.update!()

          :ok
        end
    end
  end

  defp failed(row, reason) do
    planning_step(row, :model_resume_failed)
    {:ok, _, _} = AgentSessions.fire(row, :model_resume_failed)
    {:error, {:model_resume_partial, elem(reason, 0), elem(reason, 1)}}
  end
end
