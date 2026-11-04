defmodule ForemanWeb.SessionState do
  @moduledoc """
  The one session state function (spec Decision 9): a session's lifecycle state, open
  cards, ticket stage and times become its label, badge colour and second line. Every
  page that shows a session state uses `view/2` or `badge/1`; there is no other session
  colour map.

  `view/2` takes the map from `Foreman.AgentSessions.label_facts/1` (or one built by
  hand): `state` (column value or `Foreman.SessionLifecycle` atom), `kind`,
  `open_cards` (count), `card_at` (oldest open card), `stage` (ticket stage atom),
  `state_at`, `ended_at`, `reset_at` (usage-limit reset, text or time) and
  `parent_ended_at` (a live build's ended coordinator, R8).
  """
  use ForemanWeb, :html
  alias Foreman.SessionLifecycle
  alias ForemanWeb.RelativeTime
  alias Fluxon.Components.Badge

  @review_stages [:reported, :in_review]

  @doc """
  Returns `%{label, color, variant, icon, second, at}`: `second` is the second line (or
  nil) and `at` the time it names, for the full time on hover.
  """
  def view(facts, now \\ DateTime.utc_now()) do
    state = state(Map.get(facts, :state))
    cards = Map.get(facts, :open_cards, 0)
    live? = SessionLifecycle.live?(state)

    cond do
      # R2: an open card wins, even after the session ended.
      cards > 0 or state in [:waiting_question, :waiting_permission, :waiting_usage_limit] ->
        waiting(state, cards, live?, facts, now)

      state == :idle and Map.get(facts, :kind) == "build" and
          Map.get(facts, :stage) in @review_stages ->
        label("In review", "warning", "soft")
        |> second(parent_line(facts, now) || lasting("for ", facts[:state_at], now))

      state in [:starting, :working, :none] ->
        label("Working", "info", "soft") |> second(parent_line(facts, now))

      state == :idle ->
        label("Idle", "neutral", "soft")
        |> second(parent_line(facts, now) || lasting("for ", facts[:state_at], now))

      state == :parked ->
        label("Parked", "neutral", "outline")
        |> second(since("parked ", facts[:ended_at] || facts[:state_at], now))

      state == :ended ->
        label("Ended", "neutral", "outline")
        |> second(since("ended ", facts[:ended_at] || facts[:state_at], now))
    end
  end

  defp waiting(state, cards, live?, facts, now) do
    line =
      cond do
        not live? ->
          since("ended ", facts[:ended_at] || facts[:state_at], now)

        state == :waiting_permission ->
          since("Permission prompt · ", facts[:state_at], now)

        state == :waiting_usage_limit ->
          reset(facts[:reset_at], now)

        cards > 0 ->
          since("#{cards} #{if cards == 1, do: "card", else: "cards"} · ", facts[:card_at], now)

        true ->
          since("Question · ", facts[:state_at], now)
      end

    label("Waiting on you", "primary", "solid", "hero-inbox") |> second(line)
  end

  defp reset(%DateTime{} = at, now),
    do: {"Usage limit · resets " <> RelativeTime.until(at, now), at}

  defp reset(text, _now) when is_binary(text) and text != "",
    do: {"Usage limit · resets " <> text, nil}

  defp reset(_, _), do: {"Usage limit", nil}

  # R8: a live build whose coordinator ended says so.
  defp parent_line(facts, now) do
    if at = Map.get(facts, :parent_ended_at), do: since("Parent ended ", at, now)
  end

  defp since(_prefix, nil, _now), do: nil
  defp since(prefix, at, now), do: {prefix <> RelativeTime.format(at, now), at}
  defp lasting(_prefix, nil, _now), do: nil
  defp lasting(prefix, at, now), do: {prefix <> RelativeTime.duration(at, now), at}

  defp label(label, color, variant, icon \\ nil),
    do: %{label: label, color: color, variant: variant, icon: icon, second: nil, at: nil}

  defp second(view, nil), do: view
  defp second(view, {text, at}), do: %{view | second: text, at: at}

  defp state(state) when is_atom(state), do: state
  defp state(state), do: SessionLifecycle.load(state)

  attr :id, :string, required: true
  attr :view, :map, required: true, doc: "the result of `view/2`"

  @doc "The shared badge and second line; the second line's time shows in full on hover."
  def badge(assigns) do
    ~H"""
    <span id={@id} class="inline-flex min-w-0 items-center gap-2">
      <Badge.badge id={@id <> "-label"} color={@view.color} variant={@view.variant} size="sm">
        <.icon :if={@view.icon} name={@view.icon} class="icon size-3.5" />
        {@view.label}
      </Badge.badge>
      <span
        :if={@view.second}
        id={@id <> "-second"}
        class="truncate text-xs text-foreground-softer"
        title={@view.at && DateTime.to_iso8601(@view.at)}
      >
        {@view.second}
      </span>
    </span>
    """
  end
end
