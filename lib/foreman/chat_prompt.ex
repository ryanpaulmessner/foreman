defmodule Foreman.ChatPrompt do
  @moduledoc """
  Claude Code 2.1.303's chat input as it appears in a pane, for replying to a
  question asked in plain chat. Idle means: the last thing on screen is the input
  box (a `❯` line between two rules, then at most a few footer lines), the box is
  empty, and nothing shows a running turn (an "esc to interrupt" footer, or a
  spinner line such as `✳ Concocting… (20s)` above the box). A draft, a dialog or
  a running turn refuses, so a reply never lands anywhere but an empty prompt.
  """

  @footer 4
  @rule ~r/\A─{3,}/u
  @empty_input ~r/\A[❯>]\z/u
  @spinner ~r/\A[·✢✳✶✻✽*]\s+\S+…/u

  def idle?(screen) when is_binary(screen) do
    lines =
      screen
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == ""))

    with {footer, [_bottom | rest]} <- Enum.split_while(lines, &(not rule?(&1))),
         true <- length(footer) <= @footer,
         [input, _top | above] <- rest,
         true <- rule?(Enum.at(rest, 1)),
         true <- Regex.match?(@empty_input, String.trim(input)) do
      not Enum.any?(footer, &String.contains?(&1, "esc to interrupt")) and
        not Enum.any?(Enum.take(above, 6), &Regex.match?(@spinner, &1))
    else
      _ -> false
    end
  end

  def idle?(_), do: false

  @doc "Keystrokes for a reply: the text, then Enter, sent separately."
  def keys(text) do
    with {:ok, text} <- typed(text), do: {:ok, [{:literal, text}, :enter]}
  end

  @doc "Text safe to type as one line: control characters become spaces; 1 to 2000 bytes."
  def typed(text) when is_binary(text) do
    case text |> String.replace(~r/[\x00-\x1f\x7f]+/u, " ") |> String.trim() do
      "" -> {:error, :answer_required}
      text when byte_size(text) > 2_000 -> {:error, :answer_required}
      text -> {:ok, text}
    end
  end

  def typed(_), do: {:error, :answer_required}

  defp rule?(line), do: is_binary(line) and Regex.match?(@rule, line)
end
