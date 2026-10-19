defmodule ForemanWeb.RequestCard do
  use ForemanWeb, :html
  alias Fluxon.Components.Badge
  attr :id, :string, required: true
  attr :request, :any, required: true
  attr :repos, :list, default: nil
  attr :link, :atom, default: :navigate, values: [:patch, :navigate]

  def summary(assigns) do
    ~H"""
    <article id={@id} class="space-y-2 rounded-lg border border-base p-4">
      <div class="flex flex-wrap items-center gap-2 text-xs text-foreground-softer">
        <Badge.badge>{@request.state}</Badge.badge>
        <.ticket_link id={@id <> "-ticket-link"} request={@request} link={@link} />
        <span>{@request.actor}</span>
        <span class="ml-auto"><ForemanWeb.TicketDetail.timestamp at={@request.updated_at} /></span>
      </div>
      <.waiting_facts :if={@request.kind == "session_waiting"} request={@request} />
      <.agent_text
        :if={@request.kind == "session_waiting" and @request.facts["reason"] == "question"}
        id={@id <> "-question"}
        text={@request.facts["question"]}
        repo={@request.repo_key}
        repos={@repos}
      />
      <.push_facts :if={@request.kind == "push"} request={@request} />
      <.open_pr_facts
        :if={@request.kind == "open_pr"}
        request={@request}
        repos={@repos}
        prefix={@id <> "-"}
      />
      <.merge_facts :if={@request.kind == "merge"} request={@request} />
      <.agent_text
        :if={@request.kind == "decision"}
        id={@id <> "-question"}
        text={@request.facts["question"]}
        repo={@request.repo_key}
        repos={@repos}
        class="fm-card-question"
      />
      <.doc_links id={@id <> "-docs"} request={@request} />
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

  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :repo, :string, required: true
  attr :repos, :list, default: nil
  attr :class, :any, default: nil

  @doc """
  Agent-written text as safe Markdown with document links. Long text shows its
  first lines and a Show more toggle.
  """
  def agent_text(assigns) do
    assigns =
      assign(assigns,
        html: Foreman.CardText.render(assigns.text, assigns.repo, assigns.repos),
        long: Foreman.CardText.long?(assigns.text)
      )

    ~H"""
    <div>
      <div id={@id} class={["fm-markdown fm-card-text", @long && "fm-clamp", @class]}>
        {Phoenix.HTML.raw(@html)}
      </div>
      <button
        :if={@long}
        id={@id <> "-more"}
        type="button"
        aria-controls={@id}
        aria-expanded="false"
        class="mt-1 cursor-pointer text-xs font-medium text-foreground-softer underline-offset-4 transition hover:text-foreground hover:underline"
        phx-click={
          JS.toggle_class("fm-clamp", to: "#" <> @id)
          |> JS.toggle_attribute({"aria-expanded", "true", "false"})
          |> JS.toggle(to: "#" <> @id <> "-more > span", display: "inline")
        }
      >
        <span>Show more</span><span style="display: none">Show less</span>
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :request, :any, required: true

  @doc "The documents an ask was posted with (`--doc`), as viewer links."
  def doc_links(assigns) do
    assigns = assign(assigns, :docs, List.wrap(assigns.request.facts["docs"]))

    ~H"""
    <ul :if={@docs != []} id={@id} class="mt-3 flex flex-wrap gap-2" aria-label="Documents">
      <li :for={doc <- @docs}>
        <a
          href={Foreman.Markdown.viewer_path(doc["repo"], doc["path"])}
          title={doc["path"]}
          class="inline-flex max-w-full items-center gap-1.5 rounded-md border border-base bg-sunken px-2 py-1 font-mono text-xs transition hover:border-primary hover:text-foreground"
        >
          <.icon name="hero-document-text" class="size-3.5 shrink-0" />
          <span class="truncate">{Path.basename(doc["path"])}</span>
        </a>
      </li>
    </ul>
    """
  end

  attr :id, :string, required: true
  attr :request, :any, required: true
  attr :link, :atom, required: true, values: [:patch, :navigate]

  @doc "The card's ticket, opened in the Needs you side panel. The coordinator has no ticket."
  def ticket_link(%{request: %{repo_key: "__foreman__"}} = assigns) do
    ~H"""
    <span class="font-mono">{@request.bead_id}</span>
    """
  end

  def ticket_link(assigns) do
    assigns =
      assign(
        assigns,
        :path,
        "/needs-you?" <>
          URI.encode_query(%{
            "ticket" => assigns.request.repo_key <> ":" <> assigns.request.bead_id
          })
      )

    ~H"""
    <.link
      id={@id}
      patch={if @link == :patch, do: @path}
      navigate={if @link == :navigate, do: @path}
      title="Open ticket"
      class="inline-flex items-center gap-1 rounded font-mono underline decoration-current/30 underline-offset-4 transition hover:text-foreground hover:decoration-current"
    >
      <.icon name="hero-ticket" class="size-3.5" />{@request.bead_id}
    </.link>
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
  attr :repos, :list, default: nil
  attr :prefix, :string, default: ""

  def open_pr_facts(assigns) do
    ~H"""
    <dl class="grid min-w-0 grid-cols-1 gap-x-4 gap-y-1 text-sm sm:grid-cols-[auto_1fr]">
      <div
        :for={
          {label, key} <- [
            {"Title", "title"},
            {"Repository", "remote"},
            {"Base branch", "base_branch"},
            {"Head branch", "head_branch"},
            {"Commit", "expected_sha"}
          ]
        }
        class="contents"
      >
        <dt class="mt-2 text-foreground-softer sm:mt-0">{label}</dt>
        <dd class="min-w-0 whitespace-pre-wrap break-words [overflow-wrap:anywhere]" phx-no-format>{@request.facts[key]}</dd>
      </div>
      <dt class="mt-2 text-foreground-softer sm:mt-0">Body</dt>
      <dd class="min-w-0">
        <.agent_text
          id={@prefix <> "pr-body-" <> @request.id}
          text={@request.facts["body"]}
          repo={@request.repo_key}
          repos={@repos}
        />
      </dd>
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
      <dt class="text-foreground-softer">Destination</dt>
      <dd class="min-w-0 break-all font-mono">{destination(@request.facts)}</dd>
      <div
        :for={
          {label, key} <- [
            {"Branch", "local_branch"},
            {"Commit", "expected_sha"},
            {"Worktree", "worktree"}
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

  defp destination(facts), do: "#{facts["remote"]} → #{facts["remote_branch"]}"
end
