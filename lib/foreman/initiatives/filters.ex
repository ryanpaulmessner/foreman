defmodule Foreman.Initiatives.Filters do
  @moduledoc "Validated URL values for the initiatives query. Empty values mean all."

  def normalize(params, options) when is_map(params) do
    choices = %{
      "project" => Enum.map(options.repos, & &1["key"]),
      "type" => options.types,
      "label" => options.labels,
      "status" => ~w(all open closed in_progress blocked deferred parked),
      "stale" => ["true", "false"]
    }

    Map.new(choices, fn {key, allowed} ->
      value = params[key]
      {key, if(value in allowed, do: value, else: "")}
    end)
    |> Map.put("q", if(is_binary(params["q"]), do: params["q"], else: ""))
    |> Map.put("view", view_key(params, Map.get(options, :views, [])))
  end

  def normalize(_, options), do: normalize(%{}, options)

  defp view_key(params, views) do
    cond do
      params["view"] == "" ->
        ""

      Enum.any?(views, &(&1["key"] == params["view"])) ->
        params["view"]

      not Map.has_key?(params, "view") and map_size(params) > 0 ->
        ""

      true ->
        case views do
          [first | _] -> first["key"]
          [] -> ""
        end
    end
  end

  def effective(filters, views) do
    key = if Map.has_key?(filters, "view"), do: view_key(filters, views), else: ""
    preset = Enum.find(views, %{}, &(&1["key"] == key))

    filters
    |> Map.put(
      "statuses",
      if(filters["status"] in [nil, ""], do: preset["statuses"] || [], else: [])
    )
    |> Map.put("stages", preset["stages"] || [])
    |> Map.put(
      "stale",
      if(filters["stale"] in [nil, ""],
        do: to_string(preset["stale"] || false),
        else: filters["stale"]
      )
    )
  end

  def advanced_count(filters, views) do
    preset = Enum.find(views, %{}, &(&1["key"] == filters["view"]))
    count = Enum.count(~w(type label), &(filters[&1] not in [nil, ""]))

    status_override? =
      filters["status"] not in [nil, "", "all"] or
        (filters["status"] == "all" and preset["statuses"] not in [nil, []])

    stale_override? =
      filters["stale"] == "true" or (filters["stale"] == "false" and preset["stale"] == true)

    count + Enum.count([status_override?, stale_override?], & &1)
  end

  def path(filters), do: "/?" <> URI.encode_query(Enum.sort(filters))

  def toggle_project(filters, project) do
    Map.put(filters, "project", if(filters["project"] == project, do: "", else: project))
  end
end
