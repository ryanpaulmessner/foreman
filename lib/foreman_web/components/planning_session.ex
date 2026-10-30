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
    ~H"""
    <section
      :if={@session}
      id={@id <> "-planning-session"}
      class="min-w-0 space-y-2 rounded-lg border border-base p-3 text-xs"
    >
      <div class="flex flex-wrap items-center gap-2">
        <span class="font-medium">Planning session</span>
        <span id={@id <> "-planning-state"} class="text-foreground-softer">{@session.state}</span>
        <ForemanWeb.TicketDetail.timestamp at={@session.launched_at} />
      </div>
      <p :if={@session.error} role="status">{@session.error}</p>
      <div class="flex min-w-0 items-center gap-2">
        <div class="min-w-0 flex-1 [&_.fieldset]:mb-0">
          <.input
            id={@id <> "-attach"}
            type="text"
            name="attach"
            readonly
            value={Foreman.SessionTmux.attach_command(@session)}
            aria-label="Attach command"
            class="w-full min-w-0 rounded border border-base bg-sunken px-2 py-2 font-mono text-xs"
          />
        </div>
        <button
          id={@id <> "-copy-attach"}
          type="button"
          phx-hook=".CopyAttach"
          data-command={Foreman.SessionTmux.attach_command(@session)}
          class="shrink-0 rounded border border-base px-2 py-2 hover:bg-sunken"
          aria-label="Copy attach command"
        >
          Copy
        </button>
      </div>
    </section>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyAttach">
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            navigator.clipboard.writeText(this.el.dataset.command).catch(() => {
              const input = this.el.parentElement.querySelector("input")
              input.focus()
              input.select()
            })
          })
        }
      }
    </script>
    """
  end
end
