defmodule Foreman.Week.Model do
  @moduledoc "Pure weekly page projection. All external facts are supplied by the caller."

  @kinds [
    {"feature", "Feature"},
    {"break_fix", "Break-fix"},
    {"mapping", "Mapping"},
    {"access", "Access"},
    {"internal", "Internal"},
    {"unsorted", "Unsorted"}
  ]
  @stages [
    "Shipped",
    "Done",
    "Closed, not done",
    "On staging",
    "Waiting on you",
    "Waiting on others",
    "Building",
    "Discussed"
  ]

  @doc """
  Builds sections containing stage groups and tickets from local snapshots.

  Tickets carry repository-scoped `key`, `repo`, `id`, `title`, `type`, `kind`,
  `edges`, `status`, string board `stage`, projected file `raw`, and cached `prs`.
  Events carry `key` and UTC `inserted_at`; requests also carry `id`, `kind`, and
  `state`. Optional `repos` and board `links` support effective kind resolution.
  `pr_containment` maps `{repo, number, head_sha}` to cached ancestry results.
  `sent_reports` is reserved for a later slice.
  Options are `timezone` and `week_repos`. The week end is exclusive.
  """
  def build(facts, now, opts \\ []) do
    window = window(now, Keyword.get(opts, :timezone, "America/Chicago"))
    repos = Keyword.get(opts, :week_repos, ["work"])

    activity =
      Enum.group_by(
        Map.get(facts, :events, []) ++ Map.get(facts, :requests, []),
        & &1.key,
        & &1.inserted_at
      )

    tickets =
      Foreman.Initiatives.Kinds.resolve(
        facts.tickets,
        Map.get(facts, :repos, []),
        Map.get(facts, :links, [])
      )

    nodes = Map.new(tickets, &{&1.key, &1})
    requests = Enum.group_by(Map.get(facts, :requests, []), & &1.key)

    items =
      tickets
      # Epics are the Feature sub-headings, never items of their own.
      |> Enum.filter(&(&1.repo in repos and &1.type != "epic"))
      |> Enum.flat_map(fn ticket ->
        times = Map.get(activity, ticket.key, []) ++ file_times(ticket.raw, window.timezone)

        week_times =
          Enum.filter(
            times,
            &(DateTime.compare(&1, window.start_at) != :lt and
                DateTime.compare(&1, window.end_at) == :lt)
          )

        if week_times == [] do
          []
        else
          pending =
            Map.get(requests, ticket.key, [])
            |> Enum.filter(
              &(&1.state == "pending" and
                  &1.kind in ~w(push open_pr merge decision review_ui session_waiting))
            )
            |> Enum.sort_by(& &1.id)

          epic = epic([ticket.key], nodes, MapSet.new(), Map.get(facts, :links, []))

          cache = Map.get(facts, :pr_containment, %{})
          cache = if is_map(cache), do: cache, else: %{}

          results =
            for pr <- ticket.prs,
                pr["state"] == "merged",
                do: Map.get(cache, {ticket.repo, pr["number"], pr["head_sha"]}, %{})

          stage = plain_stage(ticket, pending, results)
          last_activity = Enum.max_by(times, &DateTime.to_unix/1)

          [
            Map.merge(ticket, %{
              last_activity: last_activity,
              activity_day: activity_day(last_activity, now, window.timezone),
              progress_step: progress_step(stage, ticket),
              missing_staging:
                Enum.any?(results, &(&1[:in_production] == false and &1[:in_staging] == false)),
              plain_stage: stage,
              request_ids: Enum.map(pending, & &1.id),
              epic: epic && Map.take(epic, [:key, :title])
            })
          ]
        end
      end)

    sections =
      for {kind, label} <- @kinds,
          members = Enum.filter(items, &(&1.effective_kind == kind)),
          members != [] do
        groups =
          members
          |> Enum.group_by(fn item ->
            {if(kind == "feature", do: item.epic), item.plain_stage}
          end)
          |> Enum.sort_by(fn {{epic, stage}, _} ->
            {if(epic, do: {epic.title, epic.key}, else: {"", {"", ""}}),
             Enum.find_index(@stages, &(&1 == stage))}
          end)
          |> Enum.with_index()
          |> Enum.map(fn {{{epic, stage}, rows}, index} ->
            %{
              id: "#{kind}-#{index}",
              epic_title: epic && epic.title,
              stage: stage,
              items: Enum.sort_by(rows, &{&1.title, &1.key})
            }
          end)

        %{id: kind, kind: kind, label: label, count: length(members), groups: groups}
      end

    %{window: window, sections: sections}
  end

  @closed_prefixes ["won't do", "duplicate", "superseded", "out of scope"]
  defp plain_stage(ticket, pending, results) do
    not_done =
      String.starts_with?(
        String.downcase(String.trim(ticket.raw["close_reason"] || "")),
        @closed_prefixes
      )

    rules = [
      {results != [] and Enum.all?(results, &(&1[:in_production] == true)), "Shipped"},
      {ticket.status == "closed" and
         not Enum.any?(ticket.prs, &(&1["state"] in ["open", "merged"])) and not not_done,
       "Done"},
      {(ticket.status == "closed" and not_done) or ticket.stage == "abandoned",
       "Closed, not done"},
      {Enum.any?(
         results,
         &(&1[:in_staging] == true or
             (&1[:in_staging] == false and &1[:in_production] == false))
       ), "On staging"},
      {pending != [], "Waiting on you"},
      {ticket.status == "parked" or Enum.any?(ticket.prs, &(&1["state"] == "open")),
       "Waiting on others"},
      # Work run outside the board (relay builds, by hand) only shows in the
      # ticket file status.
      {ticket.status == "in_progress" or
         ticket.stage in ~w(dispatched building reported in_review committed), "Building"},
      # Activity without work: a note, a decision, a status change.
      {true, "Discussed"}
    ]

    Enum.find_value(rules, fn {matches, label} -> if matches, do: label end)
  end

  defp activity_day(time, now, timezone) do
    date = time |> DateTime.shift_zone!(timezone) |> DateTime.to_date()
    today = now |> DateTime.shift_zone!(timezone) |> DateTime.to_date()

    case Date.diff(today, date) do
      0 -> "Today"
      1 -> "Yesterday"
      _ -> Calendar.strftime(date, "%a")
    end
  end

  defp progress_step("Shipped", _), do: "In production"
  defp progress_step("On staging", _), do: "On staging"
  defp progress_step(stage, _) when stage in ["Done", "Closed, not done"], do: stage

  defp progress_step(stage, ticket) do
    cond do
      Enum.any?(ticket.prs, &(&1["state"] == "merged")) ->
        "Merged, checking…"

      Enum.any?(ticket.prs, &(&1["state"] == "open")) ->
        "PR open"

      stage == "Building" or ticket.status == "in_progress" or
          ticket.stage in ~w(dispatched building reported in_review committed) ->
        "Building"

      true ->
        nil
    end
  end

  defp epic([], _nodes, _seen, _links), do: nil

  defp epic(frontier, nodes, seen, links) do
    frontier = frontier |> Enum.reject(&MapSet.member?(seen, &1)) |> Enum.uniq() |> Enum.sort()
    found = Enum.find(frontier, &(nodes[&1] && nodes[&1].type == "epic"))

    if found do
      nodes[found]
    else
      parents =
        Enum.flat_map(frontier, fn key ->
          edges = if nodes[key], do: nodes[key].edges, else: []

          for(edge <- edges, edge.type in ["parent-child", "discovered-from"], do: edge.target) ++
            for link <- links, link.ticket == key, do: link.epic
        end)

      epic(parents, nodes, Enum.reduce(frontier, seen, &MapSet.put(&2, &1)), links)
    end
  end

  defp file_times(raw, timezone) do
    notes =
      Regex.scan(~r/^\s*(?:-\s*)?(\d{4}-\d{2}-\d{2})\b/m, raw["notes"] || "",
        capture: :all_but_first
      )
      |> List.flatten()

    dates = [raw["closed"] || raw["closed_at"], raw["parked"] | notes]

    Enum.flat_map(dates, fn value ->
      with true <- is_binary(value),
           {:ok, date} <- Date.from_iso8601(String.slice(value, 0, 10)) do
        [midnight(date, timezone)]
      else
        _ -> []
      end
    end)
  end

  def window(now, timezone) do
    date = now |> DateTime.shift_zone!(timezone) |> DateTime.to_date()
    monday = Date.add(date, 1 - Date.day_of_week(date))

    %{
      first_date: monday,
      last_date: Date.add(monday, 6),
      start_at: midnight(monday, timezone),
      end_at: midnight(Date.add(monday, 7), timezone),
      timezone: timezone
    }
  end

  defp midnight(date, timezone),
    do: date |> DateTime.new!(~T[00:00:00], timezone) |> DateTime.shift_zone!("Etc/UTC")
end
