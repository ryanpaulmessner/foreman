defmodule Foreman.RequestHeader do
  @moduledoc "Ticket context for a request, independent of the asker's question."
  import Ecto.Query

  def for_request(request) do
    tickets =
      Foreman.Repo.all(from b in "beads", where: b.repo_key == ^request.repo_key, select: b.raw)

    ticket = Enum.find(tickets, &(&1["id"] == request.bead_id)) || fallback_ticket(request)
    build(ticket, tickets, Foreman.RuntimeState.repos(), request.repo_key)
  end

  defp fallback_ticket(request) do
    overlay = Foreman.Overlay.get({request.repo_key, request.bead_id})
    %{"title" => (overlay && Map.get(overlay, :title)) || request.bead_id}
  end

  def build(ticket, tickets \\ [], repos \\ [], repo \\ "") do
    body = ticket["description"] || ""
    # TODO fm-49x.3: read projected Summary once the projection exposes it.
    summary = capture(~r/^## Summary\r?\n(.*?)(?=^## |\z)/ms, body) || ""

    nodes =
      Enum.map([ticket | tickets], fn raw ->
        %{
          key: {repo, raw["id"]},
          repo: repo,
          type: raw["issue_type"],
          kind: raw["kind"],
          edges:
            Enum.map(
              raw["dependencies"] || [],
              &%{type: &1["type"], target: {repo, &1["depends_on_id"]}}
            )
        }
      end)

    [resolved | _] = Foreman.Initiatives.Kinds.resolve(nodes, repos)
    epic = nearest_epic(parents(ticket), Map.new(tickets, &{&1["id"], &1}), MapSet.new())
    {origin, url} = origin(body)

    %{
      title: field(summary, "Title") || ticket["title"],
      kind: Map.new(Foreman.Initiatives.Kinds.options())[resolved.effective_kind],
      part_of: if(epic, do: epic["title"], else: "One-off"),
      from: origin,
      origin_url: url,
      summary: field(summary, "What users see")
    }
  end

  defp parents(ticket),
    do:
      for(
        edge <- ticket["dependencies"] || [],
        edge["type"] == "parent-child",
        do: edge["depends_on_id"]
      )

  defp nearest_epic([], _, _), do: nil

  defp nearest_epic(ids, tickets, seen) do
    ids = Enum.reject(ids, &MapSet.member?(seen, &1))
    nodes = ids |> Enum.map(&tickets[&1]) |> Enum.reject(&is_nil/1)

    Enum.find(nodes, &(&1["issue_type"] == "epic")) ||
      nearest_epic(
        Enum.flat_map(nodes, &parents/1),
        tickets,
        Enum.reduce(ids, seen, &MapSet.put(&2, &1))
      )
  end

  defp origin(body) do
    cond do
      id = capture(~r/^\*\*Ticket:\*\*\s*(T-\d+)/m, body) ->
        {"Support Board " <> id, nil}

      url = capture(~r/(https:\/\/app\.asana\.com\/[^\s)\]>]+)/, body) ->
        {"Asana", url}

      id = capture(~r/\bAsana\s+(\d{10,})\b/i, body) ->
        {"Asana", "https://app.asana.com/0/0/" <> id}

      true ->
        {first_sentence(body), nil}
    end
  end

  defp field(summary, label),
    do: capture(Regex.compile!("^" <> label <> ":\\s*([^\\n]+)", "m"), summary)

  defp capture(regex, text) do
    case Regex.run(regex, text, capture: :all_but_first) do
      [value] ->
        case String.trim(value) do
          "" -> nil
          value -> value
        end

      _ ->
        nil
    end
  end

  defp first_sentence(body) do
    text =
      body
      |> String.replace(~r/^## Summary\r?\n.*?(?=^## |\z)/ms, "")
      |> String.replace(~r/^\*\*Ticket:\*\*\s*none\s*$/mi, "")
      |> String.replace(~r/^\s*\#{1,6}\s+[^\n]*$/m, "")
      |> String.replace("**", "")
      |> String.trim()

    case text do
      "" ->
        nil

      text ->
        sentence = text |> String.split(~r/(?<=[.!?])\s|\n/, parts: 2) |> hd()
        if String.length(sentence) > 80, do: String.slice(sentence, 0, 80) <> "…", else: sentence
    end
  end
end
