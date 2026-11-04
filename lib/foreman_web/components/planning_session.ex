defmodule ForemanWeb.PlanningSession do
  use ForemanWeb, :html

  def launch(socket, %{"project" => project, "ticket" => ticket} = params) do
    session = Foreman.Sessions.get({project, ticket})

    result =
      case params["action"] do
        "focus" when not is_nil(session) -> Foreman.SessionTmux.focus(session)
        "relaunch" -> Foreman.Sessions.relaunch({project, ticket})
        _ -> Foreman.Sessions.launch({project, ticket})
      end

    case result do
      {:ok, :no_client} ->
        Phoenix.LiveView.put_flash(
          socket,
          :info,
          "No terminal is attached. Run: " <> Foreman.SessionTmux.attach_command(session)
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

  def launch_button(assigns) do
    focus? =
      assigns.session && assigns.session.window != nil &&
        assigns.session.state in [:starting, :running, :waiting, :ended]

    relaunch? = assigns.session && assigns.session.state in [:parked, :ended]

    label =
      cond do
        relaunch? -> "Relaunch"
        focus? -> "Focus"
        true -> "Launch"
      end

    assigns = assign(assigns, label: label, relaunch?: !!relaunch?, focus?: !!focus?)

    ~H"""
    <button
      :if={@allowed || @relaunch?}
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
      phx-disable-with={@label <> "…"}
      class="inline-flex shrink-0 items-center gap-1.5 rounded-md border border-base bg-base px-3 py-1.5 text-xs font-medium transition-colors hover:bg-sunken focus-visible:outline-2 focus-visible:outline-offset-2"
    >
      {@label}
    </button>
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
