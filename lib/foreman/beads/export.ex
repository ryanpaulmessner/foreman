defmodule Foreman.Beads.Export do
  @moduledoc """
  Pure decoder for a complete, successful `bd export` JSONL response.

  A malformed record rejects the entire response: projecting a partial export
  could delete good tickets. Unknown enum strings retain their spelling without
  creating atoms. Raw issue records retain fields not yet understood by the board.
  The SHA-256 covers the original bytes, before normalization.
  """

  @statuses %{
    "open" => :open,
    "in_progress" => :in_progress,
    "blocked" => :blocked,
    "deferred" => :deferred,
    "parked" => :parked,
    "closed" => :closed,
    "pinned" => :pinned,
    "hooked" => :hooked
  }
  @types %{
    "task" => :task,
    "feature" => :feature,
    "bug" => :bug,
    "epic" => :epic,
    "decision" => :decision,
    "chore" => :chore,
    "convoy" => :convoy
  }
  @edge_types %{
    "parent-child" => :parent_child,
    "blocks" => :blocks,
    "related" => :related,
    "discovered-from" => :discovered_from,
    "tracks" => :tracks,
    "supersedes" => :supersedes
  }
  @text_fields ~w(description acceptance_criteria notes close_reason assignee owner)a
  @date_fields ~w(created_at updated_at started_at closed_at)a

  def decode(output) when is_binary(output) do
    lines = output |> String.split("\n") |> Enum.with_index(1)

    with {:ok, beads} <- decode_lines(lines) do
      {:ok,
       %{
         beads: beads,
         sha256: :crypto.hash(:sha256, output) |> Base.encode16(case: :lower)
       }}
    end
  end

  defp decode_lines(lines) do
    Enum.reduce_while(lines, {:ok, [], MapSet.new()}, fn {line, number}, {:ok, beads, ids} ->
      if String.trim(line) == "" do
        {:cont, {:ok, beads, ids}}
      else
        with {:ok, raw} <- Jason.decode(line),
             {:ok, bead} <- normalize(raw),
             false <- MapSet.member?(ids, bead.bead_id) do
          {:cont, {:ok, [bead | beads], MapSet.put(ids, bead.bead_id)}}
        else
          _ -> {:halt, {:error, {:invalid_export, number}}}
        end
      end
    end)
    |> case do
      {:ok, beads, _ids} -> {:ok, Enum.reverse(beads)}
      error -> error
    end
  end

  defp normalize(raw) when is_map(raw) do
    with true <- Map.get(raw, "_type", "issue") == "issue",
         {:ok, id} <- required_text(raw, "id"),
         {:ok, title} <- required_text(raw, "title"),
         {:ok, status} <- required_text(raw, "status"),
         {:ok, type} <- required_text(raw, "issue_type"),
         true <- is_nil(raw["priority"]) or is_integer(raw["priority"]),
         {:ok, labels} <- list(raw, "labels", &is_binary/1),
         {:ok, edges} <- children(raw, "dependencies", &edge(&1, id)),
         {:ok, comments} <- children(raw, "comments", &comment(&1, id)),
         {:ok, text} <- fields(raw, @text_fields, &optional_text/1),
         {:ok, dates} <- fields(raw, @date_fields, &date/1) do
      {:ok,
       Map.merge(text, dates)
       |> Map.merge(%{
         bead_id: id,
         title: title,
         status: Map.get(@statuses, status, {:unknown, status}),
         issue_type: Map.get(@types, type, {:unknown, type}),
         priority: raw["priority"],
         labels: labels,
         edges: edges,
         comments: comments,
         raw: raw
       })}
    else
      _ -> :error
    end
  end

  defp normalize(_), do: :error

  defp edge(raw, id) when is_map(raw) do
    with true <- Map.get(raw, "issue_id", id) == id,
         {:ok, target} <- required_text(raw, "depends_on_id"),
         {:ok, type} <- required_text(raw, "type") do
      {:ok,
       %{
         from_bead_id: id,
         to_bead_id: target,
         type: Map.get(@edge_types, type, {:unknown, type})
       }}
    else
      _ -> :error
    end
  end

  defp edge(_, _), do: :error

  defp comment(raw, id) when is_map(raw) do
    with true <- Map.get(raw, "issue_id", id) == id,
         {:ok, author} <- required_text(raw, "author"),
         {:ok, body} <- optional_text(raw["text"]),
         true <- is_binary(body),
         {:ok, created_at} <- date(raw["created_at"]) do
      {:ok, %{author: author, body: body, created_at: created_at}}
    else
      _ -> :error
    end
  end

  defp comment(_, _), do: :error

  defp required_text(map, key) do
    case map[key] do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp optional_text(nil), do: {:ok, nil}
  defp optional_text(value) when is_binary(value), do: {:ok, value}
  defp optional_text(_), do: :error

  defp date(nil), do: {:ok, nil}

  defp date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp date(_), do: :error

  defp fields(raw, keys, normalize) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case normalize.(raw[Atom.to_string(key)]) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp list(raw, key, valid?) do
    value =
      case Map.get(raw, key) do
        nil -> []
        value -> value
      end

    if is_list(value) and Enum.all?(value, valid?), do: {:ok, value}, else: :error
  end

  defp children(raw, key, normalize) do
    with {:ok, values} <- list(raw, key, &is_map/1) do
      Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
        case normalize.(value) do
          {:ok, child} -> {:cont, {:ok, [child | acc]}}
          _ -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, children} -> {:ok, Enum.reverse(children)}
        error -> error
      end
    end
  end
end
