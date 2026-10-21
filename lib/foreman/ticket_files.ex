defmodule Foreman.TicketFiles do
  @moduledoc "Read-only snapshots of a checkout's ticket directory. Uses the shared codec."
  alias Foreman.TicketFile

  def snapshot(root) do
    directory = Path.join(root, "tickets")

    with :ok <- unlocked(root),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(directory),
         {:ok, entries} <- File.ls(directory) do
      snapshot =
        entries
        |> Enum.filter(&(Path.extname(&1) == ".md"))
        |> Map.new(fn name ->
          path = Path.join(directory, name)

          result =
            with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
                 {:ok, bytes} <- File.read(path),
                 do: {:ok, bytes}

          {name, result}
        end)

      with :ok <- unlocked(root), do: {:ok, snapshot}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "tickets: directory unavailable or not a regular directory"}
    end
  end

  def main_checkout(root) do
    case System.cmd("git", ["-C", root, "worktree", "list", "--porcelain"],
           stderr_to_stdout: true
         ) do
      {"worktree " <> output, 0} -> {:ok, output |> String.split("\n", parts: 2) |> hd()}
      _ -> {:error, "tickets: cannot resolve main checkout"}
    end
  end

  defp unlocked(root) do
    case System.cmd("git", ["-C", root, "rev-parse", "--path-format=absolute", "--git-dir"],
           stderr_to_stdout: true
         ) do
      {directory, 0} ->
        case File.lstat(Path.join(String.trim(directory), ".foreman-write-lock")) do
          {:error, :enoent} -> :ok
          _ -> {:error, "tickets: write in progress or recovery required"}
        end

      _ ->
        {:error, "tickets: cannot resolve git directory"}
    end
  end

  def decode(snapshot, previous) do
    previous = Map.new(previous, &{&1["id"], &1})

    snapshot
    |> Enum.sort()
    |> Enum.reduce({[], []}, fn {name, result}, {rows, errors} ->
      parsed =
        with {:ok, bytes} <- result,
             {:ok, ticket} <- TicketFile.parse(bytes),
             true <- ticket.facts["id"] == Path.rootname(name),
             do: {:ok, ticket}

      case parsed do
        {:ok, ticket} ->
          {[raw(ticket) | rows], errors}

        error ->
          rows =
            case previous[Path.rootname(name)] do
              nil -> rows
              old -> [old | rows]
            end

          {rows, errors ++ ["tickets/#{name}: #{reason(error)}"]}
      end
    end)
    |> then(fn {rows, errors} -> {Enum.sort_by(rows, & &1["id"]), errors} end)
  end

  defp reason({:error, reason}) when is_binary(reason), do: reason
  defp reason(false), do: "id must match filename"
  defp reason(_), do: "cannot read regular file"

  defp raw(%{facts: facts, body: body}) do
    sections = Regex.split(~r/^## /m, body)
    acceptance = section(sections, "Acceptance")
    boxes = Regex.scan(~r/^\s*- \[([ xX])\]/m, acceptance)

    edges =
      Enum.map(facts["blocked_by"], &edge(&1, "blocks")) ++
        Enum.map(facts["related"], &edge(&1, "related")) ++
        Enum.map(facts["supersedes"], &edge(&1, "supersedes")) ++
        if(facts["parent"], do: [edge(facts["parent"], "parent-child")], else: []) ++
        if(facts["discovered_from"],
          do: [edge(facts["discovered_from"], "discovered-from")],
          else: []
        )

    %{
      "id" => facts["id"],
      "title" => facts["title"],
      "issue_type" => facts["type"],
      "status" => facts["status"],
      "priority" => facts["priority"],
      "labels" => facts["labels"],
      "created_at" => timestamp(facts["created"]),
      "closed_at" => timestamp(facts["closed"]),
      "close_reason" => facts["close_reason"],
      "parked_reason" => facts["parked_reason"],
      "parked" => facts["parked"],
      "description" =>
        Regex.replace(~r/^## (?:Acceptance|Notes)\r?\n.*?(?=^## |\z)/ms, body, "")
        |> String.trim(),
      "acceptance_criteria" => acceptance,
      "notes" => section(sections, "Notes"),
      "dependencies" => edges,
      "acceptance_progress" => %{
        "checked" => Enum.count(boxes, fn [_, mark] -> mark != " " end),
        "total" => length(boxes)
      }
    }
  end

  defp timestamp(nil), do: nil
  defp timestamp(date), do: date <> "T00:00:00Z"
  defp edge(id, type), do: %{"depends_on_id" => id, "type" => type}

  defp section(sections, title) do
    Enum.find_value(sections, "", fn part ->
      case String.split(part, "\n", parts: 2) do
        [^title, text] -> String.trim(text)
        _ -> nil
      end
    end)
  end
end
