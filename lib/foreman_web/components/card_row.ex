defmodule ForemanWeb.CardRow do
  @moduledoc """
  A pending card that is not open, as one row of the card list on Needs you
  (question cards spec, Decisions 1 and 2): kind badge, the question on one line
  (full text in the tooltip), the source, the age and a chevron. The whole row
  is a button: a click, Enter or Space opens the card.
  """
  use ForemanWeb, :html
  alias Fluxon.Components.Badge

  attr :request, :any, required: true
  attr :event, :string, default: "open-card"

  def row(assigns) do
    request = assigns.request

    assigns =
      assign(assigns,
        kind: ForemanWeb.OpenCard.kind_label(request.kind),
        question: question(request),
        source: Foreman.RequestSource.view(request)
      )

    ~H"""
    <button
      id={"card-row-" <> @request.id}
      type="button"
      class="bb-tri-row"
      aria-expanded="false"
      phx-click={@event}
      phx-value-id={@request.id}
    >
      <Badge.badge>{@kind}</Badge.badge>
      <span class="bb-tri-q" title={@question}>{@question}</span>
      <span class="bb-tri-src">
        <span class={["bb-dot", @source.state != :live && "bb-dot-grey"]} aria-hidden="true"></span>
        <%= case @source.state do %>
          <% :live -> %>
            <span class="bb-tri-name">{@source.name}</span>
          <% :ended -> %>
            <span class="bb-tri-name">{@source.name}</span><span>· ended</span>
          <% :unknown -> %>
            <span>source unknown</span>
        <% end %>
      </span>
      <span class="bb-tri-age"><ForemanWeb.TicketDetail.timestamp at={@request.inserted_at} /></span>
      <.icon name="hero-chevron-down" class="bb-tri-chev size-4" />
    </button>
    """
  end

  defp question(%{kind: "session_waiting"} = request) do
    get_in(request.facts, ["questions", Access.at(0), "question"]) ||
      request.facts["question"] || Foreman.RequestHeader.title(request)
  end

  defp question(request), do: request.facts["question"] || Foreman.RequestHeader.title(request)
end
