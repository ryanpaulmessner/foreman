defmodule ForemanWeb.CardLines do
  @moduledoc """
  The lines of the card list on Needs you (question cards spec, Decisions 30-32):
  the result line that takes a card's place after you act, the info line of a
  card that closed elsewhere, and the error line of a failed action. The `*_info`
  functions build the line data that `Foreman.CardList` keeps; the components
  draw it.
  """
  use ForemanWeb, :html
  alias ForemanWeb.{CopyField, StatusLine}

  @doc "The actions that take a card out of pending, and so fire `resolved`."
  def resolving,
    do: ~w(answer batch-answer approve decline complete reply wrong-question withdraw)

  @doc """
  The result line (Decision 30) for `action` on `request` (as saved), with the
  form `params` and the source `view` (`Foreman.RequestSource.view/1`).
  """
  def result_info(action, request, params, view) do
    Map.merge(
      %{id: request.id, lead: lead(action, request, params), at: DateTime.utc_now()},
      receiver(action, view)
    )
  end

  defp lead("answer", _request, params) do
    decision = params["decision"] || %{}

    case {decision["choice"], decision["note"]} do
      {choice, _} when is_binary(choice) and choice != "" -> "Answered: #{choice}."
      _ -> "Answered with your note."
    end
  end

  defp lead("batch-answer", request, params) do
    picked = length(get_in(params, ["batch", "items"]) || [])
    "Answered: #{picked} of #{length(request.facts["items"] || [])} items."
  end

  defp lead("approve", %{kind: "push"}, _), do: "Approved: Push."
  defp lead("approve", %{kind: "open_pr"}, _), do: "Approved: Open PR."
  defp lead("approve", %{kind: "merge"}, _), do: "Approved: Merge."
  defp lead("approve", _, _), do: "Approved."
  defp lead("complete", _, _), do: "Marked done."
  defp lead("decline", _, _), do: "Declined."
  defp lead("wrong-question", _, _), do: "Sent as wrong question."
  defp lead("withdraw", _, _), do: "Withdrawn."
  defp lead("reply", request, params), do: "Replied: #{reply(request, params["reply"] || %{})}."

  defp reply(_, %{"text" => text}), do: text
  defp reply(_, %{"choice" => "other", "other" => other}), do: other

  defp reply(request, %{"choice" => choice}) do
    options = get_in(request.facts, ["questions", Access.at(0), "options"]) || []

    case Integer.parse(choice) do
      {index, ""} -> Enum.at(options, index) || choice
      _ -> choice
    end
  end

  defp reply(_, _), do: ""

  @answers ~w(answer batch-answer)

  # The receiver sentence. `before` and `after` go around the time ("just now").
  defp receiver("approve", _), do: %{before: nil, after: "The board starts it now."}

  # R9: only an answer goes to an ended session's coordinator or resumes it.
  defp receiver(action, %{receiver: receiver})
       when action in @answers and is_binary(receiver),
       do: %{before: "Sent to #{receiver} ", after: ", as a note with the question."}

  defp receiver(action, %{resumes: true, name: name}) when action in @answers,
    do: %{before: "Sent to #{name} ", after: ". The board resumed it first."}

  defp receiver(_, %{state: :live, name: name}), do: %{before: "Sent to #{name} ", after: "."}

  defp receiver(_, %{state: :ended}),
    do: %{
      before: "Saved ",
      after: ". The session that asked has ended, so no session gets it now."
    }

  defp receiver(_, _),
    do: %{
      before: "Saved ",
      after: ". The board does not know which session asked, so no session gets it."
    }

  @outcomes %{
    "answered" => "Answered",
    "declined" => "Declined",
    "wrong_question" => "Sent as wrong question",
    "done" => "Marked done",
    "approved" => "Approved",
    "withdrawn" => "Withdrawn by the agent",
    "superseded" => "Replaced because its facts changed"
  }

  # An approved push, PR or merge runs on: done or failed, it was approved.
  defp outcome(%{kind: kind, state: state})
       when kind in ~w(push open_pr merge) and
              state in ~w(executing done failed),
       do: "Approved"

  defp outcome(%{state: state}), do: @outcomes[state]

  @doc """
  The closed-elsewhere line (Decision 31) for card `id`, now `request` (or nil
  when it is gone), with the `note` you had typed and did not send.
  """
  def closed_info(id, request, note) do
    %{
      id: id,
      outcome: request && outcome(request),
      at: request && request.updated_at,
      note: if(is_binary(note) and String.trim(note) != "", do: note)
    }
  end

  @leads %{
    "answer" => "Your answer was not sent.",
    "batch-answer" => "Your answer was not sent.",
    "approve" => "Your approval was not sent.",
    "decline" => "Your decline was not sent.",
    "complete" => "Done was not saved.",
    "reply" => "Your reply was not sent.",
    "wrong-question" => "Your reason was not sent.",
    "withdraw" => "The card was not withdrawn."
  }

  @doc """
  The error line (Decision 32) for `action` on card `id` that failed with
  `reason`. `params` are kept so that Try again sends the same action.
  """
  def error_info(id, action, reason, kind, params) do
    because =
      case {action, reason} do
        {_, :database} -> ": the database did not answer"
        {"withdraw", :forbidden} -> ": only a card from an agent can be withdrawn"
        {_, reason} when reason in [:invalid, :invalid_action, :invalid_event] -> invalid()
        {_, {:invalid, _, _}} -> invalid()
        _ -> ""
      end

    sentence =
      case reason do
        {:not_delivered, name, why} ->
          "The board could not send it: #{not_delivered(name, why)}. The card stays open."

        _ ->
          "The board could not save it#{because}."
      end

    %{
      id: id,
      action: action,
      params: params,
      lead: @leads[action],
      reason: sentence,
      kept: if(kind != "chore", do: "Your choice and note are still here.")
    }
  end

  # R9: why an answer to an ended session did not reach the session or coordinator `name`.
  defp not_delivered(name, :prompt_busy), do: "#{name} is busy"
  defp not_delivered(name, :window_gone), do: "the pane of #{name} is closed"
  defp not_delivered(_, :tmux_unavailable), do: "tmux does not answer"
  defp not_delivered(name, :coordinator_not_resumable), do: "#{name} cannot resume"
  defp not_delivered(name, :still_open), do: "the old pane of #{name} is still open"
  defp not_delivered(_, "refused in preview"), do: "this preview does not write to tmux"
  defp not_delivered(name, _), do: "the board could not reach #{name}"

  defp invalid, do: ": the board does not accept this action on this card"

  attr :line, :map, required: true

  @doc "The result line of a card, in its place in the list."
  def result_line(assigns) do
    ~H"""
    <StatusLine.status_line id={"card-result-" <> @line.id} kind={:success}>
      <b class="font-semibold">{@line.lead}</b>
      {@line.before}<ForemanWeb.TicketDetail.timestamp :if={@line.before} at={@line.at} />{@line.after} It moves to Recent outcomes.
    </StatusLine.status_line>
    """
  end

  attr :line, :map, required: true

  @doc "The info line of a card that closed elsewhere, with the note you had typed."
  def closed_line(assigns) do
    ~H"""
    <StatusLine.status_line
      id={"card-info-" <> @line.id}
      kind={:info}
      close={JS.push("dismiss-line", value: %{id: @line.id})}
      close_id={"card-info-close-" <> @line.id}
    >
      <p>
        <b class="font-semibold">This card closed elsewhere.</b>
        <span :if={@line.outcome}>
          {@line.outcome} <ForemanWeb.TicketDetail.timestamp at={@line.at} />.
        </span>
      </p>
      <div :if={@line.note} class="mt-2 space-y-1">
        <p>Your note was not sent:</p>
        <CopyField.copy_field
          id={"card-info-copy-" <> @line.id}
          value={@line.note}
          label="Your note"
        />
      </div>
    </StatusLine.status_line>
    """
  end

  attr :error, :map, required: true
  attr :event, :string, default: "retry-card"

  @doc "The error line of a failed action, at the top of the card's footer strip."
  def error_line(assigns) do
    ~H"""
    <StatusLine.status_line
      id={"card-error-" <> @error.id}
      kind={:error}
      retry={JS.push(@event, value: %{id: @error.id})}
      retry_id={"card-retry-" <> @error.id}
    >
      <b class="font-semibold">{@error.lead}</b> {@error.reason} {@error.kept}
    </StatusLine.status_line>
    """
  end
end
