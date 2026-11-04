defmodule Foreman.CardContext do
  @moduledoc """
  The labelled context in an agent's card text (question cards spec, Decision 13):
  What, Why now, Part of and From. A label matches as in the ask lint
  (`Foreman.Requests.Decision`): at the start of a line, any case, optional bold,
  then a colon. A value runs to the next labelled line or the next blank line.
  Every other line is an agent note.
  """

  @labels [what: "What", why_now: "Why now", part_of: "Part of", from: "From"]
  @label ~r/\A\s*(?:\*\*)?(what|why now|part of|from)\s*:(?:\*\*)?(.*)\z/i

  @doc """
  The parsed context, or nil when the text has neither What nor Why now; the card
  then shows the text as it is.
  """
  def parse(text) when is_binary(text) do
    {values, notes, _} =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.reduce({%{}, [], nil}, &line/2)

    context =
      @labels
      |> Map.new(fn {key, _} -> {key, value(values[key])} end)
      |> Map.put(:notes, notes |> Enum.reverse() |> Enum.join("\n") |> blank())

    if context.what || context.why_now, do: context
  end

  def parse(_), do: nil

  @doc "The labels of the folded parts that exist, for the More context label."
  def parts(context) do
    for {key, label} <- [part_of: "Part of", from: "From", notes: "agent notes"],
        context[key],
        do: label
  end

  defp line(line, {values, notes, current}) do
    case Regex.run(@label, line) do
      [_, label, rest] ->
        key = key(label)

        # A label given twice keeps its first value; the second line is a note.
        if Map.has_key?(values, key),
          do: {values, [line | notes], nil},
          else: {Map.put(values, key, [rest]), notes, key}

      nil ->
        cond do
          String.trim(line) == "" -> {values, [line | notes], nil}
          current -> {Map.update!(values, current, &[line | &1]), notes, current}
          true -> {values, [line | notes], nil}
        end
    end
  end

  defp key(label) do
    label = label |> String.downcase() |> String.replace(~r/\s+/, " ")
    {key, _} = Enum.find(@labels, fn {_, name} -> String.downcase(name) == label end)
    key
  end

  defp value(nil), do: nil
  defp value(lines), do: lines |> Enum.reverse() |> Enum.map_join("\n", &String.trim/1) |> blank()

  defp blank(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end
end
