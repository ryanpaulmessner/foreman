defmodule ForemanWeb.CopyField do
  @moduledoc """
  The board's one copy pattern: a read-only mono field and a Copy button. The
  `CopyField` hook (`assets/js/copy_field.js`) shows "Copied" with a check for
  2 s, and selects the field text when the clipboard fails.
  """
  use ForemanWeb, :html
  alias Fluxon.Components.Button

  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true, doc: "accessible name of the field"
  attr :class, :any, default: nil

  def copy_field(assigns) do
    ~H"""
    <div
      id={@id}
      class={["bb-copy", @class]}
      phx-hook="CopyField"
      phx-mounted={JS.ignore_attributes(["data-copied"])}
    >
      <input
        id={@id <> "-value"}
        type="text"
        readonly
        value={@value}
        aria-label={@label}
        data-copy-value
        class="bb-copy-value font-mono"
      />
      <Button.button
        id={@id <> "-button"}
        type="button"
        size="xs"
        variant="outline"
        data-copy-button
        class="shrink-0"
      >
        <span aria-live="polite" class="contents">
          <span class="bb-copy-idle">
            <.icon name="hero-clipboard" class="size-3.5" /> Copy
          </span>
          <span class="bb-copy-done">
            <.icon name="hero-check" class="size-3.5" /> Copied
          </span>
        </span>
      </Button.button>
    </div>
    """
  end
end
