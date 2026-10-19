defmodule Foreman.OsNotifications do
  @moduledoc """
  Posts a native macOS notification (`osascript display notification`) for each
  new pending request, so the user hears about Needs you items without a board
  tab. Title "<Kind> · <ticket>", body the first line of the question. No click
  action: osascript notifications cannot open a URL.

  Runs on the worker node. `board.os_notifications` (default true) turns it
  off; on other platforms it is a no-op. Requests created before boot are never
  posted. Each request id is posted at most once per boot (`Foreman.OsNotification`).
  Request events are not durable, so a periodic scan catches missed ones.

  Agent text reaches AppleScript only as `argv` items, never as script source.
  """
  use GenServer
  alias Foreman.{OsNotification, Requests}

  @interval 15_000
  @max 200
  @script [
    "-e",
    "on run argv",
    "-e",
    "display notification (item 2 of argv) with title (item 1 of argv)",
    "-e",
    "end run"
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: Foreman.Events.subscribe()

    state = %{
      booted_at: DateTime.utc_now(),
      seen: MapSet.new(),
      runner: Keyword.get(opts, :runner, &System.cmd/3),
      platform: Keyword.get(opts, :platform, :os.type()),
      enabled: Keyword.get(opts, :enabled),
      interval: Keyword.get(opts, :interval, @interval)
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info({:notification, :foreman_events, %{"kind" => "requests_changed"}}, state),
    do: {:noreply, scan(state)}

  def handle_info(:tick, state) do
    schedule(state)
    {:noreply, scan(state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp schedule(%{interval: :infinity}), do: :ok
  defp schedule(%{interval: ms}), do: Process.send_after(self(), :tick, ms)

  defp scan(%{platform: {:unix, :darwin}} = state) do
    pending = Requests.pending()

    enabled =
      if is_nil(state.enabled), do: enabled?(Foreman.RuntimeState.config()), else: state.enabled

    seen =
      Enum.reduce(pending, state.seen, fn request, seen ->
        if MapSet.member?(seen, request.id) do
          seen
        else
          context = %{
            enabled: enabled,
            after_boot: DateTime.compare(request.inserted_at, state.booted_at) != :lt
          }

          {_, effects} = OsNotification.step(:unseen, :pending, context)
          if {:post, :notification} in effects, do: post(state.runner, message(request))
          MapSet.put(seen, request.id)
        end
      end)

    # A request leaves pending for good, so only pending ids need remembering.
    %{state | seen: MapSet.intersection(seen, MapSet.new(pending, & &1.id))}
  end

  defp scan(state), do: state

  defp post(runner, {title, body}) do
    Task.start(fn ->
      try do
        runner.("osascript", @script ++ ["--", title, body], stderr_to_stdout: true)
      rescue
        ErlangError -> :ok
      end
    end)
  end

  @doc "Whether `board.os_notifications` allows posting (default true)."
  def enabled?(%{config: %{"board" => %{"os_notifications" => false}}}), do: false
  def enabled?(_), do: true

  @doc "The notification's `{title, body}` for a request."
  def message(request) do
    ticket = if request.repo_key == "__foreman__", do: "Coordinator", else: request.bead_id
    {kind, body} = describe(request.kind, request.facts || %{})
    {kind <> " · " <> ticket, line(body) || kind}
  end

  defp describe("decision", facts), do: {"Decision", facts["question"]}

  defp describe("push", facts),
    do: {"Push", "#{facts["local_branch"]} → #{facts["remote_branch"]}"}

  defp describe("open_pr", facts), do: {"Open PR", facts["title"]}
  defp describe("merge", facts), do: {"Merge", "PR ##{facts["number"]}"}

  defp describe("session_waiting", %{"reason" => "question"} = facts),
    do: {"Question", facts["question"]}

  defp describe("session_waiting", %{"questions" => [%{"question" => question} | _]}),
    do: {"Question", question}

  defp describe("session_waiting", %{"reason" => "permission"} = facts),
    do: {"Permission needed", facts["tool_name"]}

  defp describe("session_waiting", %{"reason" => "usage_limit"} = facts),
    do: {"Usage limit", facts["provider"]}

  defp describe("session_waiting", _), do: {"Session waiting", nil}
  defp describe(_, _), do: {"Request", nil}

  # First non-blank line, without leading Markdown markers or emphasis, capped.
  defp line(text) when is_binary(text) do
    text
    |> String.replace(~r/[\x00-\x09\x0B-\x1F\x7F]/u, " ")
    |> String.split("\n")
    |> Enum.map(fn line ->
      line
      |> String.replace(~r/\A\s*(?:#+|>|[-*+]|\d+[.)])\s+/u, "")
      |> String.replace(~r/\*\*|__|`/u, "")
      |> String.trim()
    end)
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> nil
      line -> String.slice(line, 0, @max)
    end
  end

  defp line(_), do: nil
end
