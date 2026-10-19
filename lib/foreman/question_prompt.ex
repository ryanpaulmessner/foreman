defmodule Foreman.QuestionPrompt do
  @moduledoc """
  Claude Code 2.1.303's AskUserQuestion prompt as it appears in a pane, for one
  single-select question. Options are numbered from 1 and a digit picks one; the
  free-text row ("Type something.") follows them.

  A pane matches only while the visible screen shows the question, every option on
  its own numbered row and an empty free-text row. Once answered, Claude replaces
  the numbered rows with a summary, so a stale card cannot type into the session.
  """

  @other "Type something."

  def shown?(screen, %{"question" => question, "options" => options}) do
    lines = lines(screen)

    String.contains?(squish(screen), squish(question)) and
      Enum.all?(Enum.with_index(options, 1), fn {label, index} ->
        Enum.any?(lines, &row?(&1, index, label))
      end) and Enum.any?(lines, &row?(&1, length(options) + 1, @other))
  end

  def shown?(_, _), do: false

  @doc "The free-text row has the selection pointer."
  def other_focused?(screen, %{"options" => options}) do
    pattern = ~r/\A[❯>]\s*#{length(options) + 1}\.\s/u
    Enum.any?(lines(screen), &Regex.match?(pattern, &1))
  end

  @doc """
  Keystrokes for a choice. A digit commits an option at once; the free-text row
  takes its digit (focus), the text, then Enter, each as a separate send.
  """
  def keys(%{"options" => options}, {:option, index})
      when is_integer(index) and index >= 0 and index < length(options),
      do: {:ok, [{:literal, Integer.to_string(index + 1)}]}

  def keys(%{"options" => options}, {:other, text}) do
    with {:ok, text} <- Foreman.ChatPrompt.typed(text),
         do:
           {:ok,
            [{:literal, Integer.to_string(length(options) + 1)}, :focus, {:literal, text}, :enter]}
  end

  def keys(_, _), do: {:error, :answer_required}

  defp row?(line, index, label) do
    case Regex.run(~r/\A(?:[❯>]\s*)?#{index}\.\s+(.*?)(?:\s+[✔✓])?\z/u, line,
           capture: :all_but_first
         ) do
      [shown] -> shown == squish(label)
      _ -> false
    end
  end

  defp lines(screen), do: screen |> String.split("\n") |> Enum.map(&squish/1)
  defp squish(text), do: text |> String.split() |> Enum.join(" ")
end
