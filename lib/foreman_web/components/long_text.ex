defmodule ForemanWeb.LongText do
  @moduledoc """
  Long ids and paths: `overflow-wrap: anywhere` with a break opportunity after
  each "/", so a line breaks after a slash unless there is no other place.
  Each part up to a slash is one inline block, so a hyphen inside a part is not
  a break point while the part fits on a line.
  """
  use ForemanWeb, :html

  attr :text, :string, default: nil
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  def path(assigns) do
    assigns = assign(assigns, :html, slash_parts_html(assigns.text))

    ~H"""
    <span id={@id} class={["bb-path", @class]} {@rest}>{@html}</span>
    """
  end

  defp slash_parts_html(nil), do: ""

  defp slash_parts_html(text) do
    text
    |> to_string()
    |> String.split(~r{(?<=/)}, trim: true)
    |> Enum.map_join("<wbr>", fn part ->
      ~s(<span class="bb-path-part">) <>
        Phoenix.HTML.safe_to_string(Phoenix.HTML.html_escape(part)) <> "</span>"
    end)
    |> Phoenix.HTML.raw()
  end
end
