defmodule ForemanWeb.StatusLine do
  @moduledoc """
  The board's one status line: success, error and info, each with its own fill
  and icon so that colour is never the only cue. Errors that a retry can fix
  carry a Try again button. The flash group and every card line use it.
  """
  use ForemanWeb, :html
  alias Fluxon.Components.Button

  @icons %{
    success: "hero-check-circle",
    error: "hero-exclamation-triangle",
    info: "hero-information-circle"
  }

  attr :id, :string, default: nil
  attr :kind, :atom, required: true, values: [:success, :error, :info]
  attr :retry, :any, default: nil, doc: "phx-click for Try again; errors only"
  attr :retry_id, :string, default: nil
  attr :retry_target, :any, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def status_line(assigns) do
    assigns = assign(assigns, :icon, @icons[assigns.kind])

    ~H"""
    <div
      id={@id}
      role={if(@kind == :error, do: "alert", else: "status")}
      class={["bb-status", "bb-status-#{@kind}", @class]}
      {@rest}
    >
      <.icon name={@icon} class="bb-status-icon" />
      <div class="bb-status-body">{render_slot(@inner_block)}</div>
      <Button.button
        :if={@kind == :error and @retry != nil}
        id={@retry_id}
        type="button"
        size="xs"
        phx-click={@retry}
        phx-target={@retry_target}
        class="bb-status-action"
      >
        Try again
      </Button.button>
    </div>
    """
  end
end
