defmodule ForemanWeb.CardSource do
  @moduledoc """
  The card's Asked by row (question cards spec, Decision 14; Sessions spec,
  Decision 21), drawn from `Foreman.RequestSource.view/1`. It names the session
  once and says if it is live or ended. The session page link and the answer's
  receiver show when the view carries them.
  """
  use ForemanWeb, :html

  attr :id, :string, required: true
  attr :view, :map, required: true
  attr :focus_id, :string, required: true
  attr :event, :string, required: true
  attr :request_id, :string, required: true
  slot :marks, doc: "small markers at the right end of the row"

  def row(assigns) do
    ~H"""
    <div id={@id} class="bb-src">
      <%= if @view.state == :unknown do %>
        <span>The board does not know which session asked this.</span>
        <.link id={@id <> "-find"} navigate="/sessions" class="underline underline-offset-4">
          Find the session
        </.link>
      <% else %>
        <span>Asked by</span>
        <.link
          :if={@view.link}
          id={@id <> "-link"}
          navigate={@view.link}
          class="bb-src-name underline-offset-4 hover:underline"
        >
          {@view.name}
        </.link>
        <span :if={!@view.link} class="bb-src-name">{@view.name}</span>
        <span :if={@view.role} class="bb-sep" aria-hidden="true">·</span>
        <span :if={@view.role}>{@view.role}</span>
        <span class="bb-sep" aria-hidden="true">·</span>
        <span class="bb-nw">
          <%= if @view.state == :live do %>
            <span class="bb-dot" aria-hidden="true"></span><span>live</span>
          <% else %>
            <span class="bb-dot bb-dot-off" aria-hidden="true"></span>
            <span>ended <ForemanWeb.TicketDetail.timestamp at={@view.ended_at} /></span>
          <% end %>
        </span>
        <span :if={@view.receiver} class="bb-sep" aria-hidden="true">·</span>
        <span :if={@view.receiver}>answer goes to {@view.receiver}</span>
        <span :if={@view.resumes} class="bb-sep" aria-hidden="true">·</span>
        <span :if={@view.resumes}>your answer resumes it</span>
        <button
          id={@focus_id}
          type="button"
          class="bb-iconbtn"
          disabled={!@view.focus}
          title={if(@view.focus, do: "Focus terminal", else: "The pane is closed")}
          aria-label={if(@view.focus, do: "Focus terminal", else: "The pane is closed")}
          phx-click={@view.focus && @event}
          phx-value-id={@request_id}
          phx-value-action="go-session"
        >
          <.icon name="hero-command-line" class="size-3.5" />
        </button>
      <% end %>
      <span :if={@marks != []} class="bb-src-marks">{render_slot(@marks)}</span>
    </div>
    """
  end
end
