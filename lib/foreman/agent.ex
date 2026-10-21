defmodule Foreman.Agent do
  @moduledoc "Claim-only boundary shared by HTTP and durable replay."
  alias Foreman.{Overlay, Repo}
  import Ecto.Query

  def event(repo, id, params) do
    events =
      for machine <- [Foreman.Stage, Foreman.Epic],
          {event, :claimed} <- machine.__fsm__(:sources),
          do: event

    event = Enum.find(events, &(to_string(&1) == params["event"]))
    payload = params["payload"] || %{}
    actor = params["actor"] || "user"

    cond do
      is_nil(event) ->
        {422, %{error: "claimed_events_only"}}

      not is_map(payload) or not is_binary(actor) ->
        {422, %{error: "invalid_payload"}}

      true ->
        payload =
          if params["session"],
            do:
              payload
              |> Map.put_new("window", params["session"])
              |> Map.put("session", params["session"]),
            else: payload

        with :ok <- validate_target(repo, event, payload) do
          unless event == :create, do: ensure_entity({repo, id})
          result = Overlay.apply_event({repo, id}, {event, payload}, %{actor: actor})
          Foreman.Runtime.ping(repo)
          response(result)
        end
    end
  end

  defp validate_target(repo, :ticket, payload) do
    target = payload["beads_epic_id"]

    if is_binary(target) and target != "" and not String.starts_with?(target, "draft:") do
      case ensure_entity({repo, target}) do
        nil -> {404, %{error: "not_found"}}
        %{machine: Foreman.Epic} -> :ok
        _ -> {422, %{error: "beads_epic_required"}}
      end
    else
      {422, %{error: "beads_epic_required"}}
    end
  end

  defp validate_target(_, _, _), do: :ok

  def ensure_entity({repo, _} = key) do
    if is_nil(Overlay.get(key)), do: sync(repo)
    Overlay.get(key)
  end

  def sync(repo) do
    sync =
      Application.get_env(
        :foreman,
        :agent_sync,
        &Foreman.Beads.SyncJob.perform(%Oban.Job{args: %{"key" => &1}})
      )

    sync.(repo)
  end

  def link({repo, id} = key, {epic_repo, epic_id} = epic_key, action)
      when action in ["attach", "detach"] do
    ticket = ensure_entity(key)
    epic = ensure_entity(epic_key)

    cond do
      is_nil(ticket) or is_nil(epic) ->
        {404, %{error: "not_found"}}

      ticket.machine != Foreman.Stage or epic.machine != Foreman.Epic ->
        {422, %{error: "ticket_and_epic_required"}}

      true ->
        {:ok, result} =
          Repo.transaction(fn ->
            # The same lock as draft linking keeps its canonical identity stable.
            for key <- Enum.sort(Enum.uniq([repo, epic_repo])) do
              Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
                "foreman:overlay:" <> key
              ])
            end

            epic = Overlay.get(epic_key)

            if action == "attach" do
              Repo.insert_all(
                "epic_links",
                [
                  %{
                    repo_key: repo,
                    bead_id: id,
                    epic_repo_key: epic_repo,
                    epic_bead_id: epic.bead_id
                  }
                ],
                on_conflict: :nothing
              )
            else
              ids =
                Enum.uniq([epic_id, epic.bead_id, epic.beads_epic_id]) |> Enum.reject(&is_nil/1)

              Repo.delete_all(
                from l in "epic_links",
                  where:
                    l.repo_key == ^repo and l.bead_id == ^id and l.epic_repo_key == ^epic_repo and
                      l.epic_bead_id in ^ids
              )
            end

            Foreman.Events.broadcast(:overlay_changed, repo <> "/" <> id)
            Foreman.Runtime.ping(repo)
            Foreman.Runtime.ping(epic_repo)
            {200, %{stage: ticket.stage, effects: [%{kind: action, name: "epic"}]}}
          end)

        result
    end
  end

  defp response({:ok, %{stage: stage, effects: effects}}),
    do:
      {200,
       %{
         stage: stage,
         effects: Enum.map(effects, fn {kind, name} -> %{kind: kind, name: name} end)
       }}

  defp response({:error, %{stage: _, allowed: _} = result}), do: {409, result}
  defp response({:error, :not_found}), do: {404, %{error: "not_found"}}
  defp response({:error, reason}) when is_atom(reason), do: {422, %{error: reason}}
end
