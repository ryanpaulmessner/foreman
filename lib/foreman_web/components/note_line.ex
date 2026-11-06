defmodule ForemanWeb.NoteLine do
  @moduledoc """
  The sentence for a note that the board saved because its coordinator was busy
  (fm-9mm.23): it waits, it was sent, it may not have been sent, or you stopped it.
  The card's result line, Recent outcomes and the session page use it.
  """
  use ForemanWeb, :html
  alias Fluxon.Components.Button

  defdelegate waiting?(note), to: Foreman.QueuedNotes

  @doc "The status line kind for the note: sent is success, failed is error, else info."
  def kind(%{state: "sent"}), do: :success
  def kind(%{state: "failed"}), do: :error
  def kind(_), do: :info

  attr :note, :map, required: true

  @doc "The note's sentence, with the shared time format."
  def text(assigns) do
    assigns =
      assign(assigns,
        name: assigns.note.coordinator.name,
        what: if(assigns.note.kind == "relaunch", do: "The relaunch note", else: "The note")
      )

    ~H"""
    <%= case {@note.state, @note.kind} do %>
      <% {state, _} when state in ["queued", "sending"] -> %>
        <%= if @note.coordinator.ended_at do %>
          {@what} to {@name} waits until {@name} resumes.
        <% else %>
          {@what} to {@name} waits until its prompt is idle.
        <% end %>
      <% {"sent", "relaunch"} -> %>
        Sent {@name} the relaunch note <ForemanWeb.TicketDetail.timestamp at={@note.done_at} />.
      <% {"sent", _} -> %>
        Sent to {@name}
        <ForemanWeb.TicketDetail.timestamp at={@note.done_at} />, as a note with the question.
      <% {"failed", _} -> %>
        {@what} to {@name} may not have been sent: {failure(@note.reason)}.
      <% {"withdrawn", _} -> %>
        {@what} to {@name} was not sent.
    <% end %>
    """
  end

  defp failure("typing_failed"), do: "tmux stopped while the board typed it"
  defp failure(_), do: "the board stopped while it typed it"

  attr :id, :string, required: true
  attr :note, :map, required: true
  attr :event, :string, default: "withdraw-note"

  @doc "Do not send, for a waiting note."
  def withdraw(assigns) do
    ~H"""
    <Button.button
      :if={@note.state == "queued"}
      id={@id}
      type="button"
      size="xs"
      variant="outline"
      phx-click={@event}
      phx-value-note={@note.id}
      class="ml-1 align-baseline"
    >
      Do not send
    </Button.button>
    """
  end
end
