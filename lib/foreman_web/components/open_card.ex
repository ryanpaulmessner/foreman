defmodule ForemanWeb.OpenCard do
  @moduledoc """
  The open question card (question cards spec, Decisions 12-20 and 23). From top
  to bottom inside one border: the header line, the Asked by row, the question,
  What and Why now with the rest under More context, the body for the card's kind,
  the card thread, and one footer strip. The footer has one text box; the
  button decides what it is for: the primary button sends it as the note, Ask
  sends it to the session as a question, and Wrong question and Withdraw send it
  as their reason (Ryan, 2026-11-04, cards 602ad7c1 and 8ff81918).
  """
  use ForemanWeb, :html
  alias Fluxon.Components.{Badge, Button}
  alias ForemanWeb.RequestCard

  @kinds %{
    "decision" => "Decision",
    "review_ui" => "UI review",
    "batch" => "Batch",
    "chore" => "Chore",
    "push" => "Push",
    "open_pr" => "Open PR",
    "merge" => "Merge",
    "session_waiting" => "Session waiting"
  }

  @doc "The kind badge word of a request kind."
  def kind_label(kind), do: @kinds[kind] || "Decision"

  attr :id, :string, required: true
  attr :request, :any, required: true
  attr :prefix, :string, default: ""
  attr :event, :string, default: "resolve"
  attr :card, :atom, default: :ready, doc: "the session-waiting notice"
  attr :focus, :atom, default: :ready, doc: "the last Focus terminal result"
  attr :footer, :map, default: %{ask: :idle, reason: nil, text: "", choice: nil}
  attr :heading, :boolean, default: false
  attr :repos, :list, default: nil
  attr :close, :string, default: nil, doc: "the Close card event; no button when nil"
  attr :error, :map, default: nil, doc: "the error line of a failed action (ForemanWeb.CardLines)"

  def card(assigns) do
    request = assigns.request

    assigns =
      assign(assigns,
        title: Foreman.RequestHeader.title(request),
        source: Foreman.RequestSource.view(request),
        context: Foreman.CardContext.parse(request.facts["text"]),
        kind: @kinds[request.kind] || "Decision",
        link: if(assigns.prefix == "", do: :patch, else: :navigate)
      )

    ~H"""
    <article id={@id}>
      <h2 :if={@heading} data-ticket-heading="true" class="mb-3 text-base font-semibold">{@title}</h2>
      <div id={@prefix <> "card-open-" <> @request.id} class="bb-qcard">
        <div class="bb-qcard-body">
          <div class="bb-qhead">
            <Badge.badge>{@kind}</Badge.badge>
            <RequestCard.ticket_link
              id={@prefix <> "ticket-link-" <> @request.id}
              request={@request}
              link={@link}
            />
            <span class="bb-qhead-title" title={@title}>{@title}</span>
            <span class="bb-qhead-time">
              <ForemanWeb.TicketDetail.timestamp at={@request.inserted_at} />
            </span>
            <button
              :if={@close}
              id={@prefix <> "card-close-" <> @request.id}
              type="button"
              class="bb-iconbtn"
              aria-expanded="true"
              aria-label="Close card"
              title="Close card"
              phx-click={@close}
              phx-value-id={@request.id}
            >
              <.icon name="hero-chevron-up" class="size-3.5" />
            </button>
          </div>
          <ForemanWeb.CardSource.row
            id={@prefix <> "card-source-" <> @request.id}
            view={@source}
            focus_id={@prefix <> "card-focus-" <> @request.id}
            event={@event}
            request_id={@request.id}
          >
            <:marks>
              <span :if={@request.edited_at} id={@prefix <> "updated-" <> @request.id}>
                Updated <ForemanWeb.TicketDetail.timestamp at={@request.edited_at} />
              </span>
              <span :if={@request.similar_question} id={@prefix <> "duplicate-" <> @request.id}>
                Similar question
              </span>
            </:marks>
          </ForemanWeb.CardSource.row>
          <.focus_line
            id={@prefix <> "card-focus-info-" <> @request.id}
            copy_id={@prefix <> "copy-session-" <> @request.id}
            focus={@focus}
            source={@source.source}
          />
          <RequestCard.agent_text
            :if={@request.kind != "session_waiting" and @request.facts["question"]}
            id={@prefix <> "question-" <> @request.id}
            text={@request.facts["question"]}
            repo={@request.repo_key}
            repos={@repos}
            class="fm-card-question"
          />
          <.context
            :if={@context}
            id={@prefix <> "card-context-" <> @request.id}
            context={@context}
            request={@request}
            repos={@repos}
          />
          <RequestCard.agent_text
            :if={is_nil(@context) and @request.facts["text"]}
            id={@prefix <> "text-" <> @request.id}
            text={@request.facts["text"]}
            repo={@request.repo_key}
            repos={@repos}
            class="mt-2 text-foreground-softer"
          />
          <RequestCard.doc_links id={@prefix <> "docs-" <> @request.id} request={@request} />
        </div>
        {body(assigns)}
      </div>
    </article>
    """
  end

  defp body(%{request: %{kind: kind}} = assigns) when kind in ["push", "open_pr", "merge"] do
    assigns = assign(assigns, :form, to_form(%{"note" => ""}, as: :decision))

    ~H"""
    <.form
      for={@form}
      id={@prefix <> @request.kind <> "-" <> @request.id}
      phx-submit={@event}
      phx-change={@event <> "-text"}
      phx-value-id={@request.id}
    >
      <div class="bb-qcard-body space-y-3">
        <RequestCard.push_facts :if={@request.kind == "push"} request={@request} prefix={@prefix} />
        <RequestCard.open_pr_facts
          :if={@request.kind == "open_pr"}
          request={@request}
          repos={@repos}
          prefix={@prefix}
        />
        <RequestCard.merge_facts :if={@request.kind == "merge"} request={@request} />
      </div>
      <.thread request={@request} prefix={@prefix} event={@event} repos={@repos} />
      <.footer {footer_attrs(assigns, "decision")}>
        <Button.button
          id={@prefix <> "submit-approve-" <> @request.id}
          type="submit"
          name="action"
          value="approve"
          variant="solid"
          phx-disable-with="Approving…"
        >
          Approve
        </Button.button>
        <Button.button
          id={@prefix <> "submit-decline-" <> @request.id}
          type="submit"
          name="action"
          value="decline"
        >
          Decline
        </Button.button>
      </.footer>
    </.form>
    """
  end

  defp body(%{request: %{kind: "batch"}} = assigns) do
    assigns = assign(assigns, :form, to_form(%{}, as: :batch))

    ~H"""
    <.form
      for={@form}
      id={@prefix <> "batch-" <> @request.id}
      phx-submit={@event}
      phx-change={@event <> "-text"}
      phx-value-id={@request.id}
    >
      <div class="bb-qcard-body">
        <fieldset class="bb-opts">
          <legend class="sr-only">Items</legend>
          <label
            :for={{item, index} <- Enum.with_index(@request.facts["items"])}
            class="bb-opt"
          >
            <input
              id={"#{@prefix}batch-item-#{@request.id}-#{index}"}
              type="checkbox"
              name="batch[items][]"
              value={item["id"]}
              checked={item["id"] in List.wrap(@footer.choice)}
            />
            <span class="min-w-0">
              <span class="bb-opt-label block">{item["label"]}</span>
              <span
                :if={item["detail"]}
                class="bb-opt-detail block whitespace-pre-wrap"
                phx-no-format
              >{item["detail"]}</span>
            </span>
            <span></span>
          </label>
        </fieldset>
      </div>
      <.thread request={@request} prefix={@prefix} event={@event} repos={@repos} />
      <.footer {footer_attrs(assigns, "batch")}>
        <Button.button
          id={@prefix <> "submit-batch-" <> @request.id}
          type="submit"
          name="action"
          value="batch-answer"
          variant="solid"
          phx-disable-with="Submitting…"
        >
          Submit
        </Button.button>
      </.footer>
    </.form>
    """
  end

  defp body(%{request: %{kind: "chore"}} = assigns) do
    ~H"""
    <div class="bb-qcard-body">
      <ol
        id={@prefix <> "chore-steps-" <> @request.id}
        class="mt-2 list-decimal space-y-1.5 pl-5 text-sm"
      >
        <li :for={step <- @request.facts["steps"]} class="whitespace-pre-wrap break-words">{step}</li>
      </ol>
    </div>
    <.thread request={@request} prefix={@prefix} event={@event} repos={@repos} />
    <.form
      for={%{}}
      as={:chore}
      id={@prefix <> "chore-" <> @request.id}
      phx-submit={@event}
      phx-change={@event <> "-text"}
      phx-value-id={@request.id}
    >
      <.footer {footer_attrs(assigns, "chore")}>
        <Button.button
          id={@prefix <> "submit-done-" <> @request.id}
          type="submit"
          name="action"
          value="complete"
          phx-disable-with="Saving…"
          variant="solid"
        >
          Done
        </Button.button>
      </.footer>
    </.form>
    """
  end

  defp body(%{request: %{kind: "session_waiting"}} = assigns) do
    question =
      if Foreman.Request.inline_question?(Foreman.Requests.context(assigns.request), nil),
        do: hd(assigns.request.facts["questions"])

    assigns =
      assign(assigns,
        form: to_form(%{}, as: :waiting),
        other: to_form(%{"other" => ""}, as: :reply),
        reply: to_form(%{"text" => ""}, as: :reply),
        inline: question,
        chat?: assigns.request.facts["reason"] == "question",
        limit?: assigns.request.facts["reason"] == "usage_limit"
      )

    ~H"""
    <div class="bb-qcard-body">
      <div class="mt-2"><RequestCard.waiting_facts request={@request} /></div>
      <%= if @inline do %>
        <RequestCard.agent_text
          id={@prefix <> "question-" <> @request.id}
          text={@inline["question"]}
          repo={@request.repo_key}
          repos={@repos}
          class="fm-card-question mt-3"
        />
        <.form
          for={@form}
          id={@prefix <> "answer-" <> @request.id}
          phx-submit={@event}
          phx-value-id={@request.id}
          phx-value-action="reply"
          class="mt-3 grid gap-2 sm:grid-cols-2"
        >
          <Button.button
            :for={{label, index} <- Enum.with_index(@inline["options"])}
            id={@prefix <> "answer-" <> @request.id <> "-" <> Integer.to_string(index)}
            type="submit"
            name="reply[choice]"
            value={index}
            phx-disable-with="Sending…"
            class="h-auto min-h-9 justify-start whitespace-normal py-2 text-left [overflow-wrap:anywhere]"
          >
            {label}
          </Button.button>
        </.form>
        <.form
          for={@other}
          id={@prefix <> "other-" <> @request.id}
          phx-submit={@event}
          phx-value-id={@request.id}
          phx-value-action="reply"
          class="mt-2 flex gap-2"
        >
          <input
            id={@prefix <> "other-text-" <> @request.id}
            type="text"
            name="reply[other]"
            required
            maxlength="2000"
            placeholder="Other"
            aria-label="Other answer"
            class="bb-note min-w-0 flex-1"
          />
          <Button.button
            id={@prefix <> "other-send-" <> @request.id}
            type="submit"
            name="reply[choice]"
            value="other"
            phx-disable-with="Sending…"
          >
            Send
          </Button.button>
        </.form>
      <% end %>
      <%= if @chat? do %>
        <RequestCard.agent_text
          id={@prefix <> "chat-question-" <> @request.id}
          text={@request.facts["question"]}
          repo={@request.repo_key}
          repos={@repos}
          class="mt-3"
        />
        <.form
          for={@reply}
          id={@prefix <> "reply-" <> @request.id}
          phx-submit={@event}
          phx-value-id={@request.id}
          phx-value-action="reply"
          class="mt-3 flex gap-2"
        >
          <input
            id={@prefix <> "reply-text-" <> @request.id}
            type="text"
            name="reply[text]"
            required
            maxlength="2000"
            autocomplete="off"
            aria-label="Reply"
            class="bb-note min-w-0 flex-1"
          />
          <Button.button
            id={@prefix <> "reply-send-" <> @request.id}
            type="submit"
            variant="solid"
            phx-disable-with="Sending…"
          >
            Reply
          </Button.button>
        </.form>
      <% end %>
      <ul
        :if={is_nil(@inline) and is_list(@request.facts["questions"])}
        id={@prefix <> "questions-" <> @request.id}
        class="mt-3 space-y-3"
      >
        <li
          :for={{question, index} <- Enum.with_index(@request.facts["questions"])}
          class="space-y-1"
        >
          <RequestCard.agent_text
            id={@prefix <> "questions-" <> @request.id <> "-" <> Integer.to_string(index)}
            text={question["question"]}
            repo={@request.repo_key}
            repos={@repos}
            class="font-medium"
          />
          <p class="break-words text-sm text-foreground-softer">
            {Enum.join(question["options"], " · ")}
          </p>
        </li>
      </ul>
      <div :if={@card != :ready} class="mt-3 space-y-2">
        <ForemanWeb.StatusLine.status_line id={@prefix <> "notice-" <> @request.id} kind={:info}>
          {waiting_notice(@card)}
        </ForemanWeb.StatusLine.status_line>
        <ForemanWeb.CopyField.copy_field
          :if={@card == :unattached and @request.facts["attach"]}
          id={@prefix <> "attach-" <> @request.id}
          value={@request.facts["attach"]}
          label="Attach command"
        />
      </div>
    </div>
    <.thread request={@request} prefix={@prefix} event={@event} repos={@repos} />
    <.form
      for={%{}}
      as={:waiting}
      id={@prefix <> "waiting-" <> @request.id}
      phx-submit={@event}
      phx-change={@event <> "-text"}
      phx-value-id={@request.id}
    >
      <.footer {footer_attrs(assigns, "waiting")}>
        <Button.button
          id={@prefix <> "open-" <> @request.id}
          type="button"
          phx-click={@event}
          phx-value-id={@request.id}
          phx-value-action="open"
          phx-disable-with="Opening…"
          variant={if(@inline || @chat? || @limit?, do: "outline", else: "solid")}
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Open session
        </Button.button>
        <Button.button
          :if={@limit?}
          id={@prefix <> "continue-" <> @request.id}
          type="button"
          phx-click={@event}
          phx-value-id={@request.id}
          phx-value-action="continue"
          phx-disable-with="Continuing…"
          variant="solid"
        >
          Continue
        </Button.button>
      </.footer>
    </.form>
    """
  end

  defp body(assigns) do
    assigns = assign(assigns, :form, to_form(%{"note" => "", "choice" => ""}, as: :decision))

    ~H"""
    <.form
      for={@form}
      id={@prefix <> "decision-" <> @request.id}
      phx-submit={@event}
      phx-change={@event <> "-text"}
      phx-value-id={@request.id}
    >
      <div class="bb-qcard-body">
        <ForemanWeb.ReviewImages.grid
          :if={@request.kind == "review_ui"}
          request={@request}
          prefix={@prefix}
        />
        <fieldset :if={@request.facts["options"] != []} class="bb-opts">
          <legend class="sr-only">Options</legend>
          <label
            :for={{option, index} <- Enum.with_index(@request.facts["options"])}
            data-recommended={to_string(option == @request.facts["recommendation"])}
            class="bb-opt"
          >
            <input
              id={"#{@prefix}option-#{@request.id}-#{index}"}
              type="radio"
              name="decision[choice]"
              value={option}
              checked={option == @footer.choice}
            />
            <span class="min-w-0">
              <span class="bb-opt-label block">{option}</span>
              <span
                :if={get_in(@request.facts, ["option_details", option])}
                id={"#{@prefix}option-detail-#{@request.id}-#{index}"}
                class="bb-opt-detail bb-clamp-2"
              >
                {get_in(@request.facts, ["option_details", option])}
              </span>
            </span>
            <span>
              <Badge.badge :if={option == @request.facts["recommendation"]} variant="outline">
                <.icon name="hero-star" class="size-3.5" /> Recommended
              </Badge.badge>
            </span>
          </label>
        </fieldset>
      </div>
      <.thread request={@request} prefix={@prefix} event={@event} repos={@repos} />
      <.footer
        {footer_attrs(assigns, "decision")}
        row_id={@prefix <> "decision-actions-" <> @request.id}
      >
        <Button.button
          type="submit"
          name="action"
          value="answer"
          id={@prefix <> "submit-answer-" <> @request.id}
          variant="solid"
          phx-disable-with="Answering…"
        >
          Answer
        </Button.button>
        <Button.button
          type="submit"
          name="action"
          value="decline"
          id={@prefix <> "submit-decline-" <> @request.id}
        >
          Decline
        </Button.button>
      </.footer>
    </.form>
    """
  end

  attr :request, :any, required: true
  attr :prefix, :string, required: true
  attr :event, :string, required: true
  attr :repos, :list, default: nil

  defp thread(assigns) do
    ~H"""
    <.live_component
      module={ForemanWeb.CardConversation}
      id={@prefix <> "card-conversation-" <> @request.id}
      request={@request}
      prefix={@prefix}
      repos={@repos}
      class="bb-qcard-body"
    />
    """
  end

  defp footer_attrs(assigns, form) do
    Map.take(assigns, [:request, :prefix, :event, :footer, :source, :error])
    |> Map.put(:form, form)
  end

  attr :request, :any, required: true
  attr :prefix, :string, required: true
  attr :event, :string, required: true
  attr :footer, :map, required: true
  attr :source, :map, required: true
  attr :form, :string, required: true, doc: "the form the text box submits with"
  attr :error, :map, default: nil
  attr :row_id, :string, default: nil
  slot :inner_block, required: true

  defp footer(assigns) do
    assigns =
      assign(assigns,
        id: assigns.request.id,
        empty: String.trim(assigns.footer.text) == "",
        withdraw: Foreman.Requests.withdrawable?(assigns.request)
      )

    ~H"""
    <div id={@prefix <> "card-footer-" <> @id} class="bb-qfoot">
      <input type="hidden" name="card_id" value={@id} />
      <ForemanWeb.CardLines.error_line :if={@error} error={@error} />
      <div id={@row_id} class="bb-qrow">
        <.input
          id={@prefix <> "card-text-" <> @id}
          name={@form <> "[note]"}
          value={@footer.text}
          type="textarea"
          rows="1"
          maxlength="1900"
          aria-label="Note, question or reason"
          placeholder="Note, question or reason"
          phx-hook="CardText"
          phx-debounce="300"
          class="bb-note"
        />
        {render_slot(@inner_block)}
        <Button.button
          id={@prefix <> "card-ask-" <> @id}
          type="submit"
          name="action"
          value="ask"
          disabled={@empty}
          data-needs-text
          phx-mounted={JS.ignore_attributes(["disabled"])}
          phx-disable-with="Sending…"
          title={
            if(@source.state == :live, do: "Goes to #{@source.name}. The reply shows on this card.")
          }
        >
          <.icon name="hero-chat-bubble-left-ellipsis" class="size-4" /> Ask
        </Button.button>
      </div>
      <div class="bb-qrow">
        <div class="bb-qlinks">
          <.text_action
            id={@prefix <> "card-wrong-question-" <> @id}
            action="wrong-question"
            icon="hero-no-symbol"
            busy="Sending…"
            empty={@empty}
          >
            Wrong question
          </.text_action>
          <.text_action
            :if={@withdraw}
            id={@prefix <> "card-withdraw-" <> @id}
            action="withdraw"
            icon="hero-archive-box"
            busy="Withdrawing…"
            empty={@empty}
          >
            Withdraw
          </.text_action>
        </div>
      </div>
      <.ask_line request={@request} prefix={@prefix} event={@event} footer={@footer} source={@source} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :action, :string, required: true
  attr :icon, :string, required: true
  attr :busy, :string, required: true
  attr :empty, :boolean, required: true
  slot :inner_block, required: true

  defp text_action(assigns) do
    ~H"""
    <button
      id={@id}
      type="submit"
      name="action"
      value={@action}
      class="bb-tbtn"
      disabled={@empty}
      data-needs-text
      phx-mounted={JS.ignore_attributes(["disabled"])}
      phx-disable-with={@busy}
    >
      <.icon name={@icon} class="size-3.5" />{render_slot(@inner_block)}
    </button>
    """
  end

  attr :request, :any, required: true
  attr :prefix, :string, required: true
  attr :event, :string, required: true
  attr :footer, :map, required: true
  attr :source, :map, required: true

  # Decision 18: what shows when Ask did not reach the session (Foreman.CardAsk).
  defp ask_line(assigns) do
    assigns =
      assign(assigns, :copy, "[card question #{assigns.request.id}] #{assigns.footer.text}")

    ~H"""
    <div :if={@footer.ask != :idle} class="space-y-2">
      <p
        :if={@footer.ask == :copy}
        id={@prefix <> "card-question-hint-" <> @request.id}
        class="bb-hint"
      >
        {if @source.state == :unknown,
          do:
            "The board cannot send this question, because it does not know which session asked. Copy it and paste it in the agent's chat.",
          else:
            "The session that asked has ended, so the board cannot send this question. Copy it and paste it in the agent's chat."}
      </p>
      <ForemanWeb.StatusLine.status_line
        :if={@footer.ask == :failed}
        id={@prefix <> "card-question-unavailable-" <> @request.id}
        kind={:error}
        retry={JS.push(@event, value: %{id: @request.id, action: "ask", text: @footer.text})}
        retry_id={@prefix <> "card-question-retry-" <> @request.id}
      >
        {question_error(@footer.reason)}
      </ForemanWeb.StatusLine.status_line>
      <ForemanWeb.CopyField.copy_field
        id={@prefix <> "card-question-copy-" <> @request.id}
        value={@copy}
        label="Question to copy"
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :copy_id, :string, required: true
  attr :focus, :atom, required: true
  attr :source, :map, default: nil

  # Decision 19: a failed Focus terminal says why, under the source row.
  defp focus_line(assigns) do
    ~H"""
    <div :if={@focus in [:window_gone, :tmux_unavailable, :unattached]} class="mt-2 space-y-2">
      <ForemanWeb.StatusLine.status_line id={@id} kind={:info}>
        Could not focus the terminal. {%{
          window_gone: "The window is closed.",
          tmux_unavailable: "tmux does not answer.",
          unattached: "No terminal is attached."
        }[@focus]}
      </ForemanWeb.StatusLine.status_line>
      <ForemanWeb.CopyField.copy_field
        :if={@focus == :unattached and @source}
        id={@copy_id}
        value={Foreman.RequestSource.command(@source)}
        label="Command to attach the terminal"
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :context, :map, required: true
  attr :request, :any, required: true
  attr :repos, :list, default: nil

  defp context(assigns) do
    assigns = assign(assigns, :parts, Foreman.CardContext.parts(assigns.context))

    ~H"""
    <div id={@id} class="bb-ctx-box">
      <dl class="bb-ctx">
        <%= for {key, label} <- [what: "What", why_now: "Why now"], @context[key] do %>
          <dt>{label}</dt>
          <dd class="bb-clamp-2 bb-md">{markdown(@context[key], @request, @repos)}</dd>
        <% end %>
      </dl>
      <details
        :if={@parts != []}
        id={@id <> "-more"}
        class="bb-ctx-more"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>
          <.icon name="hero-chevron-right" class="bb-chev size-3.5" />
          <span class="bb-when-closed">More context: {Enum.join(@parts, ", ")}</span>
          <span class="bb-when-open">Less context</span>
        </summary>
        <dl class="bb-ctx">
          <%= for {key, label} <- [part_of: "Part of", from: "From"], @context[key] do %>
            <dt>{label}</dt>
            <dd class="bb-md">{markdown(@context[key], @request, @repos)}</dd>
          <% end %>
        </dl>
        <div :if={@context.notes} class="bb-extra bb-md">
          {markdown(@context.notes, @request, @repos)}
        </div>
      </details>
    </div>
    """
  end

  defp markdown(text, request, repos),
    do: Phoenix.HTML.raw(Foreman.CardText.render(text, request.repo_key, repos))

  defp question_error(:window_gone),
    do: "The question was not sent. The session window is closed."

  defp question_error(:prompt_busy),
    do: "The question was not sent. The session is not at an empty prompt."

  defp question_error(_), do: "The question was not sent. The board cannot reach the session."

  defp waiting_notice(state) do
    %{
      unattached: "No terminal is attached.",
      window_gone: "The session window is closed.",
      prompt_changed: "The question is no longer on screen. Open the session to answer it.",
      prompt_busy: "The session is not at its prompt. Open the session to reply.",
      tmux_unavailable: "tmux does not answer. Try again."
    }[state]
  end
end
