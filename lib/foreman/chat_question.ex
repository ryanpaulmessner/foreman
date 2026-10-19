defmodule Foreman.ChatQuestion do
  @moduledoc """
  Whether a Claude turn ended by asking the user something in plain chat.

  The check is deliberately simple: the last paragraph ends with "?", or asks in
  one of a few fixed phrases. A closing list of options belongs to the paragraph
  before it. A miss leaves the session quietly idle; a false hit costs one card.
  Only that paragraph is kept, capped at its last 1,000 characters.
  """

  @max 1_000
  @tail 262_144
  @ask ~r/\b(shall i|should i|do you want|would you like|want me to)\b|\bsay\s+["'“`]/i
  @list_item ~r/\A\s*(?:[-*+•]|\d+[.)])\s/u
  @continuation ~r/\A\s{2,}\S/u

  @doc "The question paragraph of an assistant message, or `:none`."
  def question(text) when is_binary(text) do
    case closing_paragraph(String.trim(text)) do
      {lead, question} when lead != "" ->
        if asks?(lead), do: {:ok, cap(question)}, else: :none

      _ ->
        :none
    end
  end

  def question(_), do: :none

  @doc """
  The turn's last assistant text from Stop hook input: `last_assistant_message`
  when Claude sends it, else the main thread's last assistant text in the tail of
  `transcript_path`. Nil when there is none since the user's last prompt.
  """
  def last_message(%{"last_assistant_message" => text}) when is_binary(text), do: text

  def last_message(%{"transcript_path" => path}) when is_binary(path) do
    with {:ok, lines} <- tail(path) do
      lines
      |> Enum.reverse()
      |> Enum.reduce_while(nil, fn line, nil ->
        case Jason.decode(line) do
          {:ok, entry} -> classify(entry)
          _ -> {:cont, nil}
        end
      end)
    else
      _ -> nil
    end
  end

  def last_message(_), do: nil

  defp classify(%{"isSidechain" => true}), do: {:cont, nil}

  defp classify(%{"type" => "assistant", "message" => %{"content" => content}})
       when is_list(content) do
    case for(%{"type" => "text", "text" => text} <- content, is_binary(text), do: text) do
      [] -> {:cont, nil}
      texts -> {:halt, Enum.join(texts, "\n\n")}
    end
  end

  defp classify(%{"type" => "user", "isMeta" => true}), do: {:cont, nil}

  # A typed prompt (not a tool result) means the user has spoken since.
  defp classify(%{"type" => "user", "message" => %{"content" => content}}) do
    prompt? =
      is_binary(content) or
        (is_list(content) and Enum.any?(content, &(not match?(%{"type" => "tool_result"}, &1))))

    if prompt?, do: {:halt, nil}, else: {:cont, nil}
  end

  defp classify(_), do: {:cont, nil}

  defp tail(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(path),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        offset = max(size - @tail, 0)

        case :file.pread(io, offset, @tail) do
          {:ok, data} ->
            lines = String.split(data, "\n", trim: true)
            # A window that starts mid-file starts mid-line.
            {:ok, if(offset > 0, do: Enum.drop(lines, 1), else: lines)}

          _ ->
            :error
        end
      after
        File.close(io)
      end
    else
      _ -> :error
    end
  end

  # {lead paragraph, the lead plus any closing options list}.
  defp closing_paragraph(text) do
    lines = String.split(text, "\n")
    {list, reversed_body} = Enum.split_while(Enum.reverse(lines), &list_line?/1)
    list = Enum.reverse(list)

    {body, list} =
      if Enum.any?(list, &Regex.match?(@list_item, &1)),
        do: {Enum.reverse(reversed_body), list},
        else: {lines, []}

    lead =
      body
      |> Enum.reverse()
      |> Enum.drop_while(&blank?/1)
      |> Enum.take_while(&(not blank?(&1)))
      |> Enum.reverse()

    {lead |> Enum.join("\n") |> String.trim(), (lead ++ list) |> Enum.join("\n") |> String.trim()}
  end

  # A closing options list: items, their indented continuations and blank lines.
  defp list_line?(line),
    do: blank?(line) or Regex.match?(@list_item, line) or Regex.match?(@continuation, line)

  defp blank?(line), do: String.trim(line) == ""

  defp asks?(lead) do
    Regex.match?(~r/\?[\s*_)\]"'”’`]*\z/u, lead) or Regex.match?(@ask, lead)
  end

  defp cap(text) do
    if String.length(text) > @max,
      do: "…" <> String.slice(text, -(@max - 1)..-1//1),
      else: text
  end
end
