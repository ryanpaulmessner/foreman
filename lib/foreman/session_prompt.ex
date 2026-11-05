defmodule Foreman.SessionPrompt do
  @moduledoc "Loads skill-owned templates from templates/session-launch. Built-in fallback is enabled only by test configuration."
  @workflows %{
    "epic" => "/tight-spec",
    "epic-coordinator" =>
      "orient on this epic, then dispatch its frontier in pane mode and close out under the usual rules. Touch no other epic",
    "bug" => "diagnosing-bugs",
    "feature" => "flow",
    "task" => "flow"
  }

  def render(kind, context, opts \\ []) do
    kind = if Map.has_key?(@workflows, kind), do: kind, else: "task"
    workflow = Map.fetch!(@workflows, kind)

    directory =
      Keyword.get(
        opts,
        :directory,
        Application.get_env(
          :foreman,
          :session_prompt_directory,
          Path.expand("~/.agents/skills/foreman/templates/session-launch")
        )
      )

    fallback = """
    You are the coordinator for {{ticket}} in project {{project}}.
    Read AGENTS.md and {{source}}. Start #{workflow} for this ticket.
    Keep planning scoped to this ticket. Follow the foreman skill for board updates and the house workflow for specs, build dispatch, and review. Ask the user when a decision is theirs.
    """

    template =
      case File.read(Path.join(directory, kind <> ".md")) do
        {:ok, text} ->
          text

        _ ->
          if Keyword.get(
               opts,
               :fallback,
               Application.get_env(:foreman, :session_prompt_fallback, false)
             ), do: fallback, else: {:error, :prompt_unavailable}
      end

    if is_binary(template) do
      Regex.replace(~r/\{\{(ticket|project|source)\}\}/, template, fn _, name ->
        Map.fetch!(
          context,
          %{"ticket" => :ticket, "project" => :project, "source" => :source}[name]
        )
      end)
    else
      template
    end
  end
end
