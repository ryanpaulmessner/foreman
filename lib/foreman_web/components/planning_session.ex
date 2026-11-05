defmodule ForemanWeb.PlanningSession do
  use ForemanWeb, :html

  def launch(socket, %{"project" => project, "ticket" => ticket} = params) do
    result =
      case params["action"] do
        "focus" -> Foreman.Sessions.focus({project, ticket})
        "relaunch" -> Foreman.Sessions.relaunch({project, ticket})
        _ -> Foreman.Sessions.launch({project, ticket})
      end

    case result do
      {:ok, :no_client} ->
        Phoenix.LiveView.put_flash(
          socket,
          :info,
          "No terminal is attached. Copy the attach command from Details."
        )

      :ok ->
        Phoenix.LiveView.clear_flash(socket, :error)

      {:ok, _} ->
        Phoenix.LiveView.clear_flash(socket, :error)

      {:error, reason} ->
        Phoenix.LiveView.put_flash(socket, :error, Foreman.Sessions.error_message(reason))
    end
  end

  attr :id, :string, required: true
  attr :key, :any, required: true
  attr :allowed, :boolean, required: true
  attr :session, :any, required: true
  attr :coordinator, :boolean, default: false
  attr :name_link, :boolean, default: false

  def launch_button(assigns) do
    identity =
      if assigns.coordinator,
        do: Foreman.Sessions.epic_coordinator(assigns.key),
        else: assigns.session && Foreman.AgentSessions.get(assigns.session.agent_session_id)

    retry? =
      assigns.session && assigns.session.state == :starting && is_nil(assigns.session.window)

    focus? =
      if identity,
        do: is_nil(identity.ended_at) && !retry?,
        else:
          assigns.session && assigns.session.window != nil &&
            assigns.session.state in [:starting, :running, :waiting]

    relaunch? =
      assigns.session && assigns.session.state in [:parked, :ended] &&
        (not assigns.coordinator ||
           (identity && identity.id == assigns.session.agent_session_id &&
              identity.conversation_id == assigns.session.session_id &&
              Foreman.AgentSessions.resumable?(identity)))

    {label, busy} =
      cond do
        relaunch? -> {if(assigns.coordinator, do: "Resume", else: "Relaunch"), "Resuming…"}
        focus? -> {"Focus", "Focusing…"}
        assigns.coordinator -> {"Launch coordinator", "Launching…"}
        true -> {"Launch", "Launching…"}
      end

    show? =
      if assigns.coordinator,
        do: assigns.allowed && (is_nil(identity) || retry? || focus? || relaunch?),
        else: assigns.allowed || relaunch?

    assigns =
      assign(assigns,
        label: label,
        busy: busy,
        show?: show?,
        identity: identity,
        relaunch?: !!relaunch?,
        focus?: !!focus?
      )

    ~H"""
    <button
      :if={@show?}
      id={@id}
      type="button"
      phx-click="launch-session"
      phx-value-project={elem(@key, 0)}
      phx-value-ticket={elem(@key, 1)}
      phx-value-action={
        cond do
          @relaunch? -> "relaunch"
          @focus? -> "focus"
          true -> "launch"
        end
      }
      phx-disable-with={@busy}
      class="bb-launch-control inline-flex shrink-0 items-center gap-1.5 rounded-md border border-base bg-base px-3 py-1.5 text-xs font-medium transition-colors hover:bg-sunken focus-visible:outline-2 focus-visible:outline-offset-2"
    >
      {@label}
    </button>
    <.link
      :if={@name_link && @identity}
      id={@id <> "-session"}
      navigate={~p"/sessions/#{@identity.id}"}
      class="block truncate font-mono text-xs hover:underline"
      title={@identity.name}
    >
      {@identity.name}
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :session, :any, required: true

  def status(assigns) do
    row = assigns.session && Foreman.AgentSessions.get(assigns.session.agent_session_id)
    assigns = assign(assigns, :identity, if(row, do: ForemanWeb.SessionLink.view(row)))

    ~H"""
    <ForemanWeb.SessionLink.row :if={@identity} id={@id <> "-planning-session"} session={@identity} />
    <ForemanWeb.StatusLine.status_line
      :if={@session && @session.error}
      id={@id <> "-planning-error"}
      kind={:error}
    >
      {@session.error}
    </ForemanWeb.StatusLine.status_line>
    """
  end
end
