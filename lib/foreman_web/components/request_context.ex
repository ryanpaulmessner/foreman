defmodule ForemanWeb.RequestContext do
  @moduledoc "Board-owned context and source actions shared by every pending card."
  use ForemanWeb, :html

  attr :request, :any, required: true
  attr :prefix, :string, default: ""
  attr :event, :string, default: "resolve"
  attr :focus, :atom, default: :ready
  attr :heading, :boolean, default: false

  def context(assigns) do
    assigns =
      assign(assigns,
        header: Foreman.RequestHeader.for_request(assigns.request),
        source: Foreman.RequestSource.for_request(assigns.request),
        form: to_form(%{"reason" => ""}, as: :withdraw)
      )

    # An unknown source gets no tmux command (Decision 21).
    assigns = assign(assigns, :command_source, assigns.source)

    ~H"""
    <section
      id={@prefix <> "context-" <> @request.id}
      class="mb-5 space-y-2 border-b border-base pb-4"
    >
      <h2 :if={!@heading} class="text-lg font-semibold">{@header.title}</h2>
      <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm">
        <dt class="text-foreground-softer">Kind</dt>
        <dd>{@header.kind}</dd>
        <dt class="text-foreground-softer">Part of</dt>
        <dd>{@header.part_of}</dd>
        <dt :if={@header.from} class="text-foreground-softer">From</dt>
        <dd :if={@header.from} class="break-words">
          <a :if={@header.origin_url} href={@header.origin_url} class="underline">{@header.from}</a>
          <span :if={!@header.origin_url}>{@header.from}</span>
        </dd>
      </dl>
      <p :if={@header.summary} id={@prefix <> "summary-" <> @request.id} class="text-sm">
        {@header.summary}
      </p>
      <p id={@prefix <> "source-" <> @request.id} class="break-words text-xs text-foreground-softer">
        <%= if @source do %>
          Source: {@source.name} · {@source.harness} · {@request.repo_key} · {@request.bead_id}
        <% else %>
          The board does not know which session asked this.
        <% end %>
      </p>
      <button
        :if={@source && !Map.get(@source, :ended_at)}
        id={@prefix <> "go-session-" <> @request.id}
        type="button"
        phx-click={@event}
        phx-value-id={@request.id}
        phx-value-action="go-session"
        class="rounded-md border border-base px-3 py-2 text-sm transition hover:bg-sunken"
      >
        Go to session
      </button>
      <ForemanWeb.StatusLine.status_line
        :if={@source && Map.get(@source, :ended_at)}
        id={@prefix <> "session-ended-" <> @request.id}
        kind={:info}
      >
        This session has ended.
      </ForemanWeb.StatusLine.status_line>
      <ForemanWeb.StatusLine.status_line
        :if={@focus == :window_gone}
        id={@prefix <> "session-closed-" <> @request.id}
        kind={:info}
      >
        The session window is closed.
      </ForemanWeb.StatusLine.status_line>
      <div
        :if={
          @command_source && @focus != :window_gone &&
            (!@source || @focus in [:unattached, :tmux_unavailable])
        }
        id={@prefix <> "session-command-" <> @request.id}
        class="space-y-2"
      >
        <ForemanWeb.StatusLine.status_line kind={:info}>
          {if @focus == :unattached, do: "No terminal is attached.", else: "Cannot focus the session."} Copy this command to your terminal.
        </ForemanWeb.StatusLine.status_line>
        <ForemanWeb.CopyField.copy_field
          id={@prefix <> "copy-session-" <> @request.id}
          value={Foreman.RequestSource.command(@command_source)}
          label="Command to focus the session"
        />
      </div>
      <details :if={Foreman.Requests.withdrawable?(@request)} class="text-sm">
        <summary class="w-fit cursor-pointer py-2 text-foreground-softer">Withdraw</summary>
        <.form
          for={@form}
          id={@prefix <> "withdraw-" <> @request.id}
          phx-submit={@event}
          phx-value-id={@request.id}
          phx-value-action="withdraw"
          class="mt-2 flex items-end gap-2"
        >
          <.input
            field={@form[:reason]}
            id={@prefix <> "withdraw-reason-" <> @request.id}
            label="Reason"
            required
          />
          <button type="submit" class="rounded border border-base px-3 py-2 hover:bg-sunken">
            Withdraw
          </button>
        </.form>
      </details>
    </section>
    """
  end
end
