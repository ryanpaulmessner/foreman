defmodule ForemanWeb.OpenCard do
  @moduledoc """
  The open question card (question cards spec, Decisions 12-20 and 23). From top
  to bottom inside one border: the header line, the Asked by row, the question,
  What and Why now with the rest under More context, the body for the card's kind,
  the card thread, and one footer strip with its panels.
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

  attr :id, :string, required: true
  attr :request, :any, required: true
  attr :prefix, :string, default: ""
  attr :event, :string, default: "resolve"
  attr :card, :atom, default: :ready, doc: "the session-waiting notice"
  attr :question, :any, default: :ready, doc: "the Ask about this send: :ready or {state, text}"
  attr :focus, :atom, default: :ready, doc: "the last Focus terminal result"
  attr :footer, :map, default: %{panel: :none, text: %{}}
  attr :heading, :boolean, default: false
  attr :repos, :list, default: nil

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
        <.panels
          :if={@footer.panel != :none}
          request={@request}
          prefix={@prefix}
          event={@event}
          footer={@footer}
          question={@question}
          source={@source}
        />
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
      <.footer request={@request} prefix={@prefix} event={@event} footer={@footer}>
        <.note
          field={@form[:note]}
          id={@prefix <> @request.kind <> "-note-" <> @request.id}
        />
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
      phx-value-id={@request.id}
      phx-value-action="batch-answer"
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
      <.footer request={@request} prefix={@prefix} event={@event} footer={@footer}>
        <Button.button
          id={@prefix <> "submit-batch-" <> @request.id}
          type="submit"
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
    <.footer request={@request} prefix={@prefix} event={@event} footer={@footer}>
      <Button.button
        id={@prefix <> "submit-done-" <> @request.id}
        phx-click={@event}
        phx-value-id={@request.id}
        phx-value-action="complete"
        phx-disable-with="Saving…"
        variant="solid"
      >
        Done
      </Button.button>
    </.footer>
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
    <.footer request={@request} prefix={@prefix} event={@event} footer={@footer}>
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
    """
  end

  defp body(assigns) do
    assigns = assign(assigns, :form, to_form(%{"note" => "", "choice" => ""}, as: :decision))

    ~H"""
    <.form
      for={@form}
      id={@prefix <> "decision-" <> @request.id}
      phx-submit={@event}
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
        request={@request}
        prefix={@prefix}
        event={@event}
        footer={@footer}
        row_id={@prefix <> "decision-actions-" <> @request.id}
      >
        <.note field={@form[:note]} id={@prefix <> "decision-note-" <> @request.id} />
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
        <:always :if={@request.kind == "decision"}>
          <div class="bb-check">
            <.input
              field={@form[:always]}
              id={@prefix <> "always-" <> @request.id}
              type="checkbox"
              label="Always use this answer"
              class="size-4 shrink-0 accent-current"
            />
          </div>
        </:always>
      </.footer>
    </.form>
    """
  end

  attr :field, :any, required: true
  attr :id, :string, required: true

  defp note(assigns) do
    ~H"""
    <.input
      field={@field}
      id={@id}
      type="textarea"
      rows="1"
      aria-label="Note"
      placeholder="Note (optional)"
      class="bb-note"
    />
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

  attr :request, :any, required: true
  attr :prefix, :string, required: true
  attr :event, :string, required: true
  attr :footer, :map, required: true
  attr :row_id, :string, default: nil
  slot :inner_block, required: true
  slot :always

  defp footer(assigns) do
    assigns =
      assign(
        assigns,
        :two_rows,
        assigns.request.kind in ~w(decision review_ui push open_pr merge)
      )

    ~H"""
    <div id={@prefix <> "card-footer-" <> @request.id} class="bb-qfoot">
      <div id={@row_id} class="bb-qrow">
        {render_slot(@inner_block)}
        <.actions
          :if={!@two_rows}
          request={@request}
          prefix={@prefix}
          event={@event}
          footer={@footer}
        />
      </div>
      <div :if={@two_rows} class="bb-qrow">
        {render_slot(@always)}
        <.actions request={@request} prefix={@prefix} event={@event} footer={@footer} />
      </div>
    </div>
    """
  end

  attr :request, :any, required: true
  attr :prefix, :string, required: true
  attr :event, :string, required: true
  attr :footer, :map, required: true

  defp actions(assigns) do
    assigns =
      assign(
        assigns,
        :actions,
        [
          {:ask, "ask", "Ask about this", "hero-chat-bubble-left-ellipsis"},
          {:wrong_question, "wrong-question", "Wrong question", "hero-no-symbol"}
        ] ++
          if(Foreman.Requests.withdrawable?(assigns.request),
            do: [{:withdraw, "withdraw", "Withdraw", "hero-archive-box"}],
            else: []
          )
      )

    ~H"""
    <div class="bb-qlinks">
      <button
        :for={{panel, dom, label, icon} <- @actions}
        id={@prefix <> "card-" <> dom <> "-" <> @request.id}
        type="button"
        class="bb-tbtn"
        phx-click={@event <> "-panel"}
        phx-value-id={@request.id}
        phx-value-panel={panel}
        aria-expanded={to_string(@footer.panel == panel)}
        aria-controls={@prefix <> "card-" <> dom <> "-panel-" <> @request.id}
      >
        <.icon name={icon} class="size-3.5" />{label}
      </button>
    </div>
    """
  end

  attr :request, :any, required: true
  attr :prefix, :string, required: true
  attr :event, :string, required: true
  attr :footer, :map, required: true
  attr :question, :any, required: true
  attr :source, :map, required: true

  defp panels(%{footer: %{panel: :ask}} = assigns) do
    {failed, text} =
      case assigns.question do
        {state, text} -> {state, text}
        _ -> {nil, assigns.footer.text[:ask] || ""}
      end

    assigns =
      assign(assigns,
        failed: failed,
        sendable: assigns.source.state == :live,
        form: to_form(%{"text" => text}, as: :card_question),
        text: text
      )

    ~H"""
    <div class="bb-qfoot bb-qfoot-panel">
      <div id={@prefix <> "card-ask-panel-" <> @request.id} class="bb-panelbox">
        <.form
          for={@form}
          id={@prefix <> "card-question-form-" <> @request.id}
          phx-submit={@event}
          phx-change={@event <> "-text"}
          phx-value-id={@request.id}
          phx-value-action="card-question"
          class="grid gap-2"
        >
          <input type="hidden" name="card" value={@request.id} />
          <input type="hidden" name="panel" value="ask" />
          <.input
            field={@form[:text]}
            id={@prefix <> "card-question-text-" <> @request.id}
            type="textarea"
            label="Ask about this"
            maxlength="1900"
            rows="2"
            required
            phx-debounce="300"
            class="bb-field"
          />
          <div :if={@sendable and is_nil(@failed)} class="bb-qrow">
            <Button.button
              id={@prefix <> "card-question-send-" <> @request.id}
              type="submit"
              size="sm"
              phx-disable-with="Sending…"
            >
              Send question
            </Button.button>
            <span class="bb-hint">Goes to {@source.name}. The reply shows on this card.</span>
          </div>
          <p :if={!@sendable} id={@prefix <> "card-question-hint-" <> @request.id} class="bb-hint">
            {if @source.state == :unknown,
              do:
                "The board cannot send this question, because it does not know which session asked. Copy it and paste it in the agent's chat.",
              else:
                "The session that asked has ended, so the board cannot send this question. Copy it and paste it in the agent's chat."}
          </p>
        </.form>
        <ForemanWeb.StatusLine.status_line
          :if={@failed}
          id={@prefix <> "card-question-unavailable-" <> @request.id}
          kind={:error}
          retry={
            JS.push(@event,
              value: %{id: @request.id, action: "card-question", card_question: %{text: @text}}
            )
          }
          retry_id={@prefix <> "card-question-retry-" <> @request.id}
        >
          {question_error(@failed)}
        </ForemanWeb.StatusLine.status_line>
        <ForemanWeb.CopyField.copy_field
          :if={!@sendable or @failed}
          id={@prefix <> "card-question-copy-" <> @request.id}
          value={"[card question #{@request.id}] #{@text}"}
          label="Question to copy"
        />
      </div>
    </div>
    """
  end

  defp panels(%{footer: %{panel: :wrong_question}} = assigns) do
    assigns =
      assign(
        assigns,
        :form,
        to_form(%{"reason" => assigns.footer.text[:wrong_question] || ""}, as: :wrong_question)
      )

    ~H"""
    <div class="bb-qfoot bb-qfoot-panel">
      <.form
        for={@form}
        id={@prefix <> "wrong-question-" <> @request.id}
        phx-submit={@event}
        phx-change={@event <> "-text"}
        phx-value-id={@request.id}
        phx-value-action="wrong-question"
        class="bb-panelbox"
      >
        <input type="hidden" name="card" value={@request.id} />
        <input type="hidden" name="panel" value="wrong_question" />
        <.input
          field={@form[:reason]}
          id={@prefix <> "wrong-question-reason-" <> @request.id}
          type="textarea"
          label="What is wrong with the question?"
          required
          rows="2"
          phx-debounce="300"
          class="bb-field"
        />
        <div class="bb-qrow">
          <Button.button
            id={@prefix <> "submit-wrong-question-" <> @request.id}
            type="submit"
            size="sm"
            phx-disable-with="Sending…"
          >
            Send as wrong question
          </Button.button>
          <span class="bb-hint">The card closes and the agent gets your reason.</span>
        </div>
      </.form>
    </div>
    """
  end

  defp panels(%{footer: %{panel: :withdraw}} = assigns) do
    assigns =
      assign(
        assigns,
        :form,
        to_form(%{"reason" => assigns.footer.text[:withdraw] || ""}, as: :withdraw)
      )

    ~H"""
    <div class="bb-qfoot bb-qfoot-panel">
      <.form
        for={@form}
        id={@prefix <> "withdraw-" <> @request.id}
        phx-submit={@event}
        phx-change={@event <> "-text"}
        phx-value-id={@request.id}
        phx-value-action="withdraw"
        class="bb-panelbox"
      >
        <input type="hidden" name="card" value={@request.id} />
        <input type="hidden" name="panel" value="withdraw" />
        <.input
          field={@form[:reason]}
          id={@prefix <> "withdraw-reason-" <> @request.id}
          label="Reason"
          required
          phx-debounce="300"
          class="bb-field"
        />
        <div class="bb-qrow">
          <Button.button
            id={@prefix <> "submit-withdraw-" <> @request.id}
            type="submit"
            size="sm"
            phx-disable-with="Withdrawing…"
          >
            Withdraw card
          </Button.button>
          <span class="bb-hint">The card closes. The agent gets the reason.</span>
        </div>
      </.form>
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
