defmodule Foreman.SessionHistory do
  @moduledoc "Read-only session history. Dispatch intervals keep another build's ticket events out."
  import Ecto.Query
  alias Foreman.{Repo, Overlay}

  def title(row) do
    if row.project && row.ticket do
      Repo.one(
        from b in "beads",
          where: b.repo_key == ^row.project and b.bead_id == ^row.ticket,
          select: fragment("?->>'title'", b.raw)
      ) || row.name
    else
      row.name
    end
  end

  def rounds(row) do
    events = stage_events(row) ++ cards(row.id)

    events
    |> Enum.sort_by(&{time(&1.at), &1.id})
    |> Enum.reduce([], fn event, rounds ->
      case rounds do
        [] ->
          [%{id: 1, events: [event]}]

        [current | older] when event.kind in ["dispatch", "request_changes"] ->
          [%{id: current.id + 1, events: [event]}, current | older]

        [current | older] ->
          [%{current | events: current.events ++ [event]} | older]
      end
    end)
    |> Enum.reverse()
  end

  defp stage_events(%{project: project, ticket: ticket} = row)
       when is_binary(project) and is_binary(ticket) do
    events = Overlay.history({project, ticket})

    starts =
      Repo.all(
        from s in "sessions",
          where: s.agent_session_id == type(^row.id, :binary_id),
          select: s.started_at
      )

    dispatches = Enum.filter(events, &(&1.event == "dispatch" and &1.outcome == "row"))

    owned =
      for at <- starts,
          event = Enum.filter(dispatches, &(time(&1.inserted_at) <= time(at))) |> List.last(),
          event,
          do: event.id

    {selected, _} =
      Enum.reduce(events, {[], false}, fn event, {acc, active} ->
        active =
          if event.event == "dispatch" and event.outcome == "row",
            do: event.id in owned,
            else: active

        include =
          if starts == [],
            do:
              row.kind != "build" and time(event.inserted_at) >= time(row.started_at) and
                (is_nil(row.ended_at) or time(event.inserted_at) <= time(row.ended_at)),
            else: active

        {if(include, do: [event | acc], else: acc), active}
      end)

    for event <- selected do
      %{
        id: "stage-#{event.id}",
        kind: if(event.outcome == "row", do: event.event, else: "result"),
        label:
          if(event.outcome == "invalid",
            do: "Refused: " <> label(event.event),
            else: label(event.event)
          ),
        at: event.inserted_at,
        text: event.payload["body"] || event.payload["path"] || event.payload["reason"],
        href: nil
      }
    end
  end

  defp stage_events(_), do: []

  defp cards(id) do
    Repo.all(from r in Foreman.Requests.Request, where: r.agent_session_id == ^id)
    |> Enum.map(fn card ->
      %{
        id: "card-#{card.id}",
        kind: "card",
        label: "Card",
        at: card.inserted_at,
        text: card.facts["question"],
        href: "/needs-you#request-#{card.id}"
      }
    end)
  end

  defp label("dispatch"), do: "Dispatched"
  defp label("request_changes"), do: "Changes requested"
  defp label("progress"), do: "Progress"
  defp label("report"), do: "Report"
  defp label("review"), do: "Review started"
  defp label(event), do: event |> String.replace("_", " ") |> String.capitalize()
  defp time(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp time(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> time()
  defp time(nil), do: 0
end
