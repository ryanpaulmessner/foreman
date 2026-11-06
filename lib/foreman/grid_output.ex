defmodule Foreman.GridOutput do
  @moduledoc "Six-line terminal excerpts; Claude's prompt and status chrome are excluded."
  def excerpt(text, harness) do
    lines = String.split(text, "\n")
    lines = if harness == "claude", do: trim_claude(lines), else: lines

    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(plain(&1) == ""))
    |> Enum.take(6)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp trim_claude(lines) do
    # Only a ruled input box near the bottom is chrome, not prompts quoted in output.
    candidate =
      Enum.with_index(lines)
      |> Enum.reverse()
      |> Enum.find(fn {line, index} ->
        String.starts_with?(plain(line), "❯") and index >= length(lines) - 12 and index > 0 and
          rule?(Enum.at(lines, index - 1))
      end)

    case candidate do
      {_, index} -> Enum.take(lines, index - 1)
      nil -> lines
    end
  end

  defp rule?(line), do: Regex.match?(~r/^[─━\-]{8,}$/, plain(line))
  defp plain(line), do: line |> String.replace(~r/\e\[[0-9;]*m/, "") |> String.trim()
end
