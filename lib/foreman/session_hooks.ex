defmodule Foreman.SessionHooks do
  @moduledoc "Per-launch settings for Claude Code 2.1.303. Hooks never control Claude's permission decision."

  def settings(session, opts \\ []) do
    # Resolve in the initialized pane, not against the web release's bin directory.
    executable = Keyword.get(opts, :hook_executable, "foreman")

    url = Keyword.get(opts, :hook_url, System.get_env("FOREMAN_URL", "http://127.0.0.1:4747"))

    token_file =
      Application.get_env(:foreman, :token_file) || System.get_env("FOREMAN_TOKEN_FILE")

    token_env = if token_file, do: " FOREMAN_TOKEN_FILE=" <> quote_arg(token_file), else: ""

    hooks =
      for event <-
            ~w(PermissionRequest Stop UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure StopFailure Notification),
          into: %{} do
        args = [
          executable,
          "session-hook",
          event,
          session.ticket,
          "--session",
          session.session_id,
          "--project",
          session.project
        ]

        command =
          "(" <>
            token_env <>
            " FOREMAN_URL=" <>
            quote_arg(url) <>
            " timeout -k 1 3 " <>
            Enum.map_join(args, " ", &quote_arg/1) <> ") >/dev/null 2>&1 || true"

        entry = %{"hooks" => [%{"type" => "command", "command" => command, "timeout" => 4}]}

        entry =
          if event == "Notification",
            do: Map.put(entry, "matcher", "quota_auto_resume_fired"),
            else: entry

        {event, [entry]}
      end

    %{"hooks" => hooks}
  end

  def facts("PermissionRequest", %{"tool_name" => "AskUserQuestion"} = input),
    do: {:waiting, question(input)}

  # The tool name only: permission input can hold command text and secrets.
  def facts("PermissionRequest", input),
    do:
      {:waiting,
       %{"reason" => "permission", "tool" => tool(input), "tool_name" => input["tool_name"]}}

  # Only the closing question paragraph leaves the pane, never the rest of the turn.
  def facts("Stop", input) do
    case input |> Foreman.ChatQuestion.last_message() |> Foreman.ChatQuestion.question() do
      {:ok, question} -> {:waiting, %{"reason" => "question", "question" => question}}
      :none -> {:waiting, %{"reason" => "input"}}
    end
  end

  def facts("PreToolUse", %{"tool_name" => "AskUserQuestion"} = input),
    do: {:waiting, question(input)}

  def facts("PreToolUse", _), do: {:resumed, "activity"}

  def facts("Notification", %{"notification_type" => "quota_auto_resume_fired"}),
    do: {:resumed, "activity"}

  def facts("UserPromptSubmit", _), do: {:resumed, nil}

  def facts(event, input) when event in ~w(PostToolUse PostToolUseFailure),
    do: {:resumed, tool(input)}

  def facts("StopFailure", input) do
    message =
      Enum.map_join(
        [input["error"], input["error_details"], input["last_assistant_message"]],
        " ",
        fn
          value when is_binary(value) -> value
          _ -> ""
        end
      )

    if Regex.match?(~r/usage.limit|extra.usage|rate.limit|429|quota/i, message) do
      reset =
        case Regex.run(~r/resets?\s+([^\n·]+)/i, message, capture: :all_but_first) do
          [time] -> String.trim(time)
          _ -> nil
        end

      {:waiting, %{"reason" => "usage_limit", "provider" => "Anthropic", "reset_at" => reset}}
    else
      :activity
    end
  end

  def facts(_, _), do: :ignore

  defp question(input) do
    %{
      "reason" => "input",
      "tool" => tool(input),
      "tool_name" => "AskUserQuestion",
      "questions" => questions(input["tool_input"])
    }
  end

  # Question text and option labels only; descriptions, preview text and answers
  # stay out. A question with previews draws a side-by-side layout where a digit
  # only moves the pointer, so it is flagged rather than answered from the card.
  defp questions(%{"questions" => questions}) when is_list(questions) do
    for %{"question" => text} = question <- questions, is_binary(text) do
      options = Enum.filter(List.wrap(question["options"]), &is_map/1)

      %{
        "question" => text,
        "options" => for(%{"label" => label} <- options, is_binary(label), do: label),
        "multi" => question["multiSelect"] == true,
        "preview" => Enum.any?(options, &Map.has_key?(&1, "preview"))
      }
    end
  end

  defp questions(_), do: []

  # PermissionRequest does not expose tool_use_id in this Claude version.
  # Hash only name/input, never the response or sensitive command text in the DB.
  defp tool(%{"tool_name" => "AskUserQuestion", "tool_input" => input}) do
    # Claude adds answers/annotations to tool_input on PostToolUse.
    fingerprint(%{
      "tool_name" => "AskUserQuestion",
      "tool_input" => Map.take(input, ["questions"])
    })
  end

  defp tool(input), do: fingerprint(Map.take(input, ~w(tool_name tool_input)))

  defp fingerprint(input),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(input)) |> Base.encode16()

  defp quote_arg(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
