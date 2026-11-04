defmodule ForemanWeb.SessionLink do
  @moduledoc "Compact identity row for ticket and epic session links."
  use ForemanWeb, :html

  def view(row) do
    %{
      id: row.id,
      row: row,
      source: Foreman.RequestSource.view(%{agent_session_id: row.id}),
      state: ForemanWeb.SessionState.view(Foreman.AgentSessions.label_facts(row))
    }
  end

  attr :id, :string, required: true
  attr :session, :map, required: true

  def row(assigns) do
    ~H"""
    <div id={@id} class="flex flex-wrap items-center gap-x-3 gap-y-2 text-xs">
      <ForemanWeb.SessionState.badge id={@id <> "-state"} view={@session.state} />
      <.link
        id={@id <> "-link"}
        navigate={@session.source.link}
        class="break-all font-mono font-medium underline-offset-4 hover:underline"
      >
        {@session.row.name}
      </.link>
      <span class="text-foreground-softer">{@session.source.role}</span>
      <span class="text-foreground-softer">
        Last seen
        <ForemanWeb.TicketDetail.timestamp at={@session.row.last_seen_at || @session.row.started_at} />
      </span>
    </div>
    """
  end
end
