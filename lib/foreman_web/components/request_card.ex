defmodule ForemanWeb.RequestCard do
  use ForemanWeb, :html
  alias Fluxon.Components.Badge
  attr :id, :string, required: true
  attr :request, :any, required: true

  def summary(assigns) do
    ~H"""
    <article id={@id} class="space-y-2 rounded-lg border border-base p-4">
      <div class="flex flex-wrap items-center gap-2 text-xs text-foreground-softer">
        <Badge.badge>{@request.state}</Badge.badge>
        <span class="font-mono">{@request.bead_id}</span>
        <span>{@request.actor}</span>
        <span class="ml-auto"><ForemanWeb.TicketDetail.timestamp at={@request.updated_at} /></span>
      </div>
      <.waiting_facts :if={@request.kind == "session_waiting"} request={@request} />
      <.push_facts :if={@request.kind == "push"} request={@request} />
      <.open_pr_facts :if={@request.kind == "open_pr"} request={@request} />
      <.merge_facts :if={@request.kind == "merge"} request={@request} />
      <p :if={@request.kind == "decision"} class="break-words font-medium">
        {@request.facts["question"]}
      </p>
      <p :if={@request.outcome["answer"]} class="whitespace-pre-wrap break-words" phx-no-format>{@request.outcome["answer"]}</p>
      <p
        :if={@request.note not in [nil, "", @request.outcome["answer"]]}
        class="whitespace-pre-wrap break-words text-foreground-softer"
        phx-no-format
      >{@request.note}</p>
      <p :if={@request.outcome["reason"]} class="text-foreground-softer">
        {String.replace(@request.outcome["reason"], "_", " ")}
      </p>
    </article>
    """
  end

  attr :request, :any, required: true

  def waiting_facts(assigns) do
    ~H"""
    <div class="space-y-1">
      <h2 class="break-words text-lg font-semibold [overflow-wrap:anywhere]">
        {session_title(@request)}
      </h2>
      <p
        :if={@request.facts["title"]}
        class="break-words text-sm text-foreground-softer [overflow-wrap:anywhere]"
      >
        {@request.facts["title"]}
      </p>
      <p class="break-words text-sm font-medium [overflow-wrap:anywhere]">
        {waiting_reason(@request.facts)}
        <span :if={@request.facts["reason"] == "permission" and @request.facts["tool_name"]}>
          {" · " <> @request.facts["tool_name"]}
        </span>
        <span :if={@request.facts["provider"]}>{" · " <> @request.facts["provider"]}</span>
        <span :if={@request.facts["reset_at"]}>{" · resets " <> @request.facts["reset_at"]}</span>
      </p>
    </div>
    """
  end

  @doc "The waiting session in words: never a tmux target."
  def session_title(%{repo_key: "__foreman__", bead_id: "coordinator"}), do: "Coordinator"
  def session_title(%{facts: %{"target" => "planning"}}), do: "Planning session"
  def session_title(%{session: session}) when is_binary(session), do: session
  def session_title(_), do: "Session"

  defp waiting_reason(%{"reason" => "input", "questions" => [_ | _]}), do: "Question"
  defp waiting_reason(%{"reason" => "question"}), do: "Question"
  defp waiting_reason(%{"reason" => "input"}), do: "Input needed"
  defp waiting_reason(%{"reason" => "permission"}), do: "Permission needed"
  defp waiting_reason(%{"reason" => "usage_limit"}), do: "Usage limit"
  defp waiting_reason(_), do: "Waiting"

  attr :request, :any, required: true

  def open_pr_facts(assigns) do
    ~H"""
    <dl class="grid min-w-0 grid-cols-1 gap-x-4 gap-y-1 text-sm sm:grid-cols-[auto_1fr]">
      <div
        :for={
          {label, key} <- [
            {"Repository", "remote"},
            {"Head branch", "head_branch"},
            {"SHA", "expected_sha"},
            {"Base branch", "base_branch"},
            {"Title", "title"},
            {"Body", "body"}
          ]
        }
        class="contents"
      >
        <dt class="mt-2 text-foreground-softer sm:mt-0">{label}</dt>
        <dd class="min-w-0 whitespace-pre-wrap break-words [overflow-wrap:anywhere]" phx-no-format>{@request.facts[key]}</dd>
      </div>
    </dl>
    """
  end

  attr :request, :any, required: true

  def merge_facts(assigns) do
    ~H"""
    <dl class="grid min-w-0 grid-cols-1 gap-x-4 gap-y-1 text-sm sm:grid-cols-[auto_1fr]">
      <dt class="text-foreground-softer">Repository</dt>
      <dd class="break-all font-mono">{@request.facts["remote"]}</dd>
      <dt class="text-foreground-softer">Pull request</dt>
      <dd class="font-mono">#{@request.facts["number"]}</dd>
      <dt class="text-foreground-softer">Head</dt>
      <dd class="break-all font-mono">{@request.facts["expected_sha"]}</dd>
    </dl>
    """
  end

  attr :request, :any, required: true

  def push_facts(assigns) do
    ~H"""
    <dl class="grid min-w-0 grid-cols-1 gap-x-4 gap-y-1 text-sm sm:grid-cols-[auto_1fr]">
      <div
        :for={
          {label, key} <- [
            {"Repository", "remote"},
            {"Worktree", "worktree"},
            {"Local branch", "local_branch"},
            {"SHA", "expected_sha"},
            {"Remote branch", "remote_branch"}
          ]
        }
        class="contents"
      >
        <dt class="mt-2 text-foreground-softer sm:mt-0">{label}</dt>
        <dd class="min-w-0 break-all font-mono">{@request.facts[key]}</dd>
      </div>
    </dl>
    """
  end
end
