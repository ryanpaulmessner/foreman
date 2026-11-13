defmodule Foreman.DocLayout do
  @moduledoc """
  Layout rules for agent-written documents (docs/specs/doc-layout.md, decisions 1-3).

  Paths in and out are repo-relative with `/` separators; the caller joins them to the
  main checkout. `foreman doc path` builds paths with `ticket_path/3`, `next_ticket_path/3`
  and `note_path/3`; `foreman check` judges added files with `classify/2`.
  """

  @rounded ~w(brief message report review)
  @ticket_kinds ~w(brief message report review loop pr plan evidence)
  @note_kinds ~w(research diagnostic audit update message check decision retro)
  @always ~w(README.md AGENTS.md CLAUDE.md CHANGELOG.md)
  # Words in an invented file name that point at a ticket kind.
  @kind_words Map.new(@ticket_kinds, &{&1, &1}) |> Map.put("prompt", "brief")
  @slug_max 40

  def ticket_kinds, do: @ticket_kinds
  def note_kinds, do: @note_kinds

  @doc """
  Path for a ticket document in round `round` (default 1). Round 1 has no suffix except
  `message`, which is always `message-r<N>.md`; `loop`, `pr`, `plan` and `evidence` have
  no rounds.
  """
  def ticket_path(kind, ticket_id, round \\ 1) do
    with :ok <- ticket_kind(kind),
         :ok <- ticket_id(ticket_id) do
      {:ok, "builds/#{ticket_id}/" <> name(kind, round)}
    end
  end

  @doc "The next free round for `kind` in `root`'s `builds/<ticket-id>/` (highest round + 1)."
  def next_ticket_path(root, kind, ticket_id) do
    with {:ok, _} <- ticket_path(kind, ticket_id) do
      names =
        case File.ls(Path.join([root, "builds", ticket_id])) do
          {:ok, names} -> names
          {:error, _} -> []
        end

      rounds = for name <- names, {:ok, ^kind, round} <- [parse_name(name)], do: round
      ticket_path(kind, ticket_id, if(rounds == [], do: 1, else: Enum.max(rounds) + 1))
    end
  end

  @doc "`notes/<date>-<kind>-<slug>.md`; the slug is lowercase kebab-case, at most 40 characters."
  def note_path(kind, slug, %Date{} = date) do
    cond do
      kind not in @note_kinds ->
        {:error, "unknown note kind #{inspect(kind)}; allowed kinds: #{list(@note_kinds)}"}

      not slug?(slug) ->
        {:error,
         "slug must be lowercase kebab-case, at most #{@slug_max} characters " <>
           "(got #{inspect(slug)}); allowed kinds: #{list(@note_kinds)}"}

      true ->
        {:ok, "notes/#{Date.to_iso8601(date)}-#{kind}-#{slug}.md"}
    end
  end

  @doc """
  Judge a repo-relative path against the layout.

  Rules: `allow:` globs (`*`, `**`, `?`), `legacy:` folders, and `prefixes:` (ticket
  prefixes used to spot a ticket id in an invented name). Returns `:allowed`,
  `{:legacy, folder, command}` for a file under a legacy folder (the caller decides whether
  it is new), or `{:refused, reason, command}`. `command` is the `foreman doc path` call
  that gives the right path; placeholders are in angle brackets.
  """
  def classify(path, rules \\ []) do
    segments = String.split(path, "/", trim: true)

    cond do
      List.last(segments) in @always ->
        :allowed

      Enum.any?(Keyword.get(rules, :allow, []), &glob?(&1, path)) ->
        :allowed

      true ->
        case layout(segments) do
          :ok ->
            :allowed

          {:error, reason} ->
            command = suggest(segments, Keyword.get(rules, :prefixes, []))

            case Enum.find(Keyword.get(rules, :legacy, []), &under?(path, &1)) do
              nil -> {:refused, reason, command}
              folder -> {:legacy, folder(folder), command}
            end
        end
    end
  end

  # Decision 1: the layout table, plus tickets/.
  defp layout(["docs", name]), do: md(name, "docs/ holds only <name>.md")

  defp layout(["docs", "specs", name]) do
    if slug?(Path.rootname(name, ".design.md") |> Path.rootname(".md")) and
         String.ends_with?(name, ".md"),
       do: :ok,
       else: {:error, "docs/specs/ holds <slug>.md and <slug>.design.md"}
  end

  defp layout(["docs", "specs", slug, _ | _]),
    do: if(slug?(slug), do: :ok, else: {:error, "docs/specs/<slug>/ needs a kebab-case slug"})

  defp layout(["docs", "adr", name]) do
    if Regex.match?(~r/\A[0-9]{4}-(.+)\.md\z/, name) and slug?(String.slice(name, 5..-4//1)),
      do: :ok,
      else: {:error, "docs/adr/ holds NNNN-<slug>.md"}
  end

  defp layout(["docs", "machines", name]), do: md(name, "docs/machines/ holds <name>.md")
  defp layout(["handoffs", name]), do: md(name, "handoffs/ holds <coordinator>.md")
  defp layout(["tickets", name]), do: md(name, "tickets/ holds <ticket-id>.md")

  defp layout(["notes", name]) do
    with [_, date, kind, slug] <- Regex.run(~r/\A(\d{4}-\d{2}-\d{2})-([a-z]+)-(.+)\.md\z/, name),
         {:ok, date} <- Date.from_iso8601(date),
         path = "notes/" <> name,
         {:ok, ^path} <- note_path(kind, slug, date) do
      :ok
    else
      _ -> {:error, "notes/ holds <YYYY-MM-DD>-<kind>-<slug>.md"}
    end
  end

  defp layout(["builds", id | rest]) do
    with :ok <- ticket_id(id) do
      case rest do
        ["evidence", _ | _] ->
          :ok

        [name] ->
          if match?({:ok, _, _}, parse_name(name)),
            do: :ok,
            else: {:error, "#{name} is not a fixed name in builds/#{id}/"}

        _ ->
          {:error, "builds/#{id}/ holds fixed names and evidence/ only"}
      end
    else
      _ -> {:error, "builds/ holds <ticket-id>/ folders"}
    end
  end

  defp layout(_), do: {:error, "not a layout path"}

  defp md(name, reason) do
    if String.ends_with?(name, ".md") and byte_size(name) > 3,
      do: :ok,
      else: {:error, reason}
  end

  # The inverse of name/2: {:ok, kind, round} for a fixed name in builds/<ticket-id>/.
  defp parse_name(file) do
    case Regex.run(~r/\A([a-z]+)(?:-r([1-9][0-9]*))?\.md\z/, file) do
      [_, kind] when kind in @ticket_kinds and kind != "message" and kind != "evidence" ->
        {:ok, kind, 1}

      [_, kind, round] when kind in @rounded ->
        round = String.to_integer(round)
        if name(kind, round) == file, do: {:ok, kind, round}, else: :error

      _ ->
        :error
    end
  end

  defp name("evidence", _), do: "evidence"
  defp name("message", round), do: "message-r#{round}.md"
  defp name(kind, round) when kind in @rounded and round > 1, do: "#{kind}-r#{round}.md"
  defp name(kind, _), do: kind <> ".md"

  defp suggest(segments, prefixes) do
    {id, words} =
      case segments do
        ["builds", id, file | _] -> {if(ticket_id(id) == :ok, do: id), words(file)}
        _ -> {find_id(Enum.join(segments, "/"), prefixes), words(List.last(segments) || "")}
      end

    kind = Enum.find_value(words, &@kind_words[&1])

    cond do
      kind && (is_binary(id) or kind not in @note_kinds or match?(["builds" | _], segments)) ->
        command([kind, id || "<ticket-id>"] ++ if(kind in @rounded, do: ["--next"], else: []))

      id ->
        command(["<kind>", id])

      true ->
        note_kind = Enum.find(words, &(&1 in @note_kinds))

        slug =
          words
          |> Enum.reject(&(&1 == note_kind or Regex.match?(~r/\A\d+\z/, &1)))
          |> Enum.join("-")
          |> String.slice(0, @slug_max)
          |> String.trim_trailing("-")

        command(["note", note_kind || "<kind>", if(slug == "", do: "<slug>", else: slug)])
    end
  end

  defp command(args), do: Enum.join(["foreman", "doc", "path" | args], " ")

  defp words(file),
    do: file |> Path.rootname() |> String.downcase() |> String.split(~r/[^a-z0-9]+/, trim: true)

  defp find_id(path, prefixes) do
    Enum.find_value(prefixes, fn prefix ->
      case Regex.run(
             ~r/(?<![a-z0-9])#{Regex.escape(prefix)}-[a-z0-9]+(?:\.[1-9][0-9]*)*/,
             String.downcase(path)
           ) do
        [id] -> id
        nil -> nil
      end
    end)
  end

  defp ticket_kind(kind) when kind in @ticket_kinds, do: :ok

  defp ticket_kind(kind),
    do: {:error, "unknown document kind #{inspect(kind)}; allowed kinds: #{list(@ticket_kinds)}"}

  defp ticket_id(id) do
    if Foreman.TicketFile.valid_id?(id),
      do: :ok,
      else: {:error, "invalid ticket id #{inspect(id)}"}
  end

  defp slug?(slug),
    do:
      is_binary(slug) and byte_size(slug) <= @slug_max and
        Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug)

  defp folder(folder), do: String.trim_trailing(folder, "/") <> "/"
  defp under?(path, folder), do: String.starts_with?(path, folder(folder))

  @doc "Match a repo-relative path using the docs.allow glob rules."
  def glob?(glob, path) do
    pattern =
      Regex.split(~r/\*\*\/|\*\*|\*|\?/, glob, include_captures: true)
      |> Enum.map_join(fn
        "**/" -> "(?:.*/)?"
        "**" -> ".*"
        "*" -> "[^/]*"
        "?" -> "[^/]"
        literal -> Regex.escape(literal)
      end)

    Regex.match?(~r/\A#{pattern}\z/, path)
  end

  defp list(kinds), do: Enum.join(kinds, ", ")
end
