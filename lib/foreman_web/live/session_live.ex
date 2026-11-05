defmodule ForemanWeb.SessionLive do
  use ForemanWeb, :live_view
  alias Foreman.{AgentSessions, PaneCapture, PaneReader, RequestSource, SessionPage}
  alias Foreman.{SessionCaptures, SessionControlPanel, SessionControls, SessionHistory}
  alias Foreman.{SessionPane, SessionsConnection}
  alias ForemanWeb.{AnsiHtml, RelativeTime, SessionState}
  alias Fluxon.Components.Button
  import ForemanWeb.TicketDetail, only: [timestamp: 1]

  def mount(_, _, socket) do
    if connected?(socket) do
      Foreman.Events.subscribe()
      Process.send_after(self(), :reconcile, 3_000)
      send(self(), :check_tmux)
    end

    {:ok,
     socket
     |> assign(disclosures: %{}, connected: connected?(socket), visible: true)
     |> assign(reader: PaneReader.__fsm__(:initial), reader_data: PaneReader.data())
     |> assign(timer: nil, capturing: false, captured: nil, shown: nil, retry_result: nil)
     |> assign(saved: nil, tmux: SessionsConnection.__fsm__(:initial), tmux_at: nil)
     |> assign(panel: SessionControlPanel.__fsm__(:initial), result: nil, panel_key: nil)
     |> assign(message_form: message_form(), sent: 0)
     |> stream_configure(:rounds, dom_id: &"session-round-#{&1.id}")}
  end

  def handle_params(%{"id" => id} = params, _, socket),
    do: {:noreply, socket |> assign(session_id: id, selected_tab: params["tab"]) |> refresh()}

  def handle_info({:notification, :foreman_events, _}, socket), do: {:noreply, refresh(socket)}

  def handle_info(:reconcile, socket) do
    Process.send_after(self(), :reconcile, 3_000)
    {:noreply, socket |> check_tmux() |> refresh()}
  end

  def handle_info(:check_tmux, socket), do: {:noreply, socket |> check_tmux() |> refresh()}

  def handle_info(:pane_tick, socket),
    do: {:noreply, socket |> assign(timer: nil) |> read(:tick)}

  # The pane reader (spec Decision 14): the capture runs outside the page process.
  def handle_async(:pane_capture, {:ok, {:ok, text}}, socket) do
    hash = PaneCapture.hash(text)

    socket
    |> assign(capturing: false, captured: {text, hash})
    |> read({:captured, %{hash: hash, at: DateTime.utc_now()}})
    |> then(&{:noreply, &1})
  end

  def handle_async(:pane_capture, _failed, socket) do
    socket
    |> assign(capturing: false)
    |> read(:failed)
    |> then(&{:noreply, &1})
  end

  def handle_event("output-visibility", %{"visible" => visible}, socket),
    do: {:noreply, socket |> assign(visible: visible == true) |> view_pane()}

  def handle_event("retry-output", _, socket),
    do: {:noreply, read(socket, :retry)}

  # Try again now (Decision 17): one tmux read; the output reader retries with it.
  def handle_event("retry-tmux", _, socket) do
    socket = socket |> check_tmux() |> refresh() |> read(:retry)

    if socket.assigns.tmux == :tmux_error,
      do: {:noreply, show_result(socket, {:error, "tmux still does not answer."})},
      else: {:noreply, panel(socket, :act)}
  end

  @controls %{"focus" => :focus, "continue" => :continue, "park" => :park}

  def handle_event("control", %{"control" => name}, socket) when is_map_key(@controls, name),
    do: {:noreply, run_control(socket, @controls[name], %{})}

  def handle_event("ask-stop", _, socket), do: {:noreply, panel(socket, :ask_stop)}
  def handle_event("keep-running", _, socket), do: {:noreply, panel(socket, :keep)}
  def handle_event("stop", _, socket), do: {:noreply, run_control(socket, :stop, %{})}

  def handle_event("send-message", %{"message" => %{"text" => text}}, socket) do
    case Foreman.ChatPrompt.typed(text) do
      {:ok, _} ->
        socket = run_control(socket, :message, %{"text" => text})

        if socket.assigns.result && elem(socket.assigns.result, 0) == :success,
          # A new input element: the browser keeps typed text in an input LiveView did not change.
          do:
            {:noreply,
             socket |> assign(:message_form, message_form()) |> update(:sent, &(&1 + 1))},
          else: {:noreply, assign(socket, :message_form, message_form(text))}

      _ ->
        {:noreply, assign(socket, :message_form, message_form(text, "Enter a message."))}
    end
  end

  def handle_event("toggle-round", %{"round" => round}, socket) do
    case Integer.parse(round) do
      {number, ""} when number > 0 and number <= socket.assigns.round ->
        current =
          Map.get(
            socket.assigns.disclosures,
            number,
            if(number == socket.assigns.round, do: :expanded, else: :collapsed)
          )

        {next, []} = Foreman.Initiatives.Disclosure.step(current, :toggle, %{})

        {:noreply,
         socket
         |> assign(:disclosures, Map.put(socket.assigns.disclosures, number, next))
         |> refresh()}

      _ ->
        {:noreply, socket}
    end
  end

  defp refresh(socket) do
    row = AgentSessions.get(socket.assigns.session_id)
    rounds = if row, do: SessionHistory.rounds(row), else: []
    # Coordinators have no review rounds (fm-9mm.21): one ungrouped list.
    grouped = not is_nil(row) and row.kind == "build"

    rounds =
      if grouped or rounds == [],
        do: rounds,
        else: [%{id: 1, events: Enum.flat_map(rounds, & &1.events)}]

    number = max(length(rounds), 1)
    parent = row && AgentSessions.get(row.parent_id)
    resumable = row && AgentSessions.resumable?(row)

    state =
      if row,
        do:
          row
          |> AgentSessions.label_facts()
          |> Map.merge(%{
            # Coordinators have no review rounds (fm-9mm.21).
            round: if(row.kind == "build", do: number),
            coordinator: parent && parent.name,
            resumable: resumable,
            output_at: row.output_at
          })
          |> SessionState.view()

    {tab, []} =
      SessionPage.step(
        :output,
        {:params,
         %{
           tab: socket.assigns.selected_tab,
           waiting: state && state.label == "Waiting on you",
           dead: row && not is_nil(row.ended_at)
         }},
        %{}
      )

    cards = if row, do: AgentSessions.open_cards(row.id), else: []

    rounds =
      Enum.map(
        rounds,
        &Map.merge(&1, %{
          grouped: grouped,
          open:
            Map.get(
              socket.assigns.disclosures,
              &1.id,
              if(&1.id == number, do: :expanded, else: :collapsed)
            ) == :expanded
        })
      )

    socket
    |> assign(
      row: row,
      state: state,
      tab: tab,
      round: number,
      title: row && SessionHistory.title(row),
      parent: parent,
      source: row && RequestSource.view(%{agent_session_id: row.id}),
      card: List.first(cards),
      provider: provider(cards),
      resumable: resumable,
      repos: Foreman.RuntimeState.repos(),
      saved: if(row && row.ended_at && tab == :output, do: SessionCaptures.get(row.id))
    )
    |> assign_controls(
      row && SessionControls.controls(row, cards: length(cards), tmux: tmux(socket, row))
    )
    |> stream(:rounds, rounds, reset: true)
    |> view_pane()
    |> changed()
  end

  # Decision 10: the panel's one filled button, the other controls that work now, then
  # the one line for the controls that are off.
  defp assign_controls(socket, nil),
    do:
      assign(socket,
        controls: [],
        primary: nil,
        tmux_down: false,
        stop: false,
        row_controls: [],
        unavailable: ""
      )

  defp assign_controls(socket, controls) do
    primary = primary(socket.assigns.row, controls, socket.assigns.card)

    assign(socket,
      controls: controls,
      primary: primary,
      tmux_down: on?(controls, :retry),
      stop: on?(controls, :stop),
      unavailable: unavailable(controls),
      row_controls:
        Enum.filter([:answer, :continue, :focus, :park], &(&1 != primary and on?(controls, &1)))
    )
  end

  # The confirm and the result line close when the session changes under them.
  defp changed(%{assigns: %{row: row, panel_key: key}} = socket) do
    if key != nil and panel_key(row) != key, do: panel(socket, :changed), else: socket
  end

  defp panel_key(nil), do: nil
  defp panel_key(row), do: {row.state, row.ended_at}

  defp tmux(socket, row), do: if(is_nil(row.ended_at), do: socket.assigns.tmux, else: :live)

  defp panel(socket, event) do
    case SessionControlPanel.step(socket.assigns.panel, event, %{}) do
      {:error, _} ->
        socket

      {state, effects} ->
        socket =
          assign(socket,
            panel: state,
            panel_key: if(state == :ready, do: nil, else: panel_key(socket.assigns.row))
          )

        if {:clear, :result} in effects, do: assign(socket, :result, nil), else: socket
    end
  end

  defp show_result(socket, result),
    do: socket |> panel(:done) |> assign(:result, result)

  defp run_control(%{assigns: %{row: row}} = socket, control, params) when not is_nil(row) do
    outcome = SessionControls.run(row, control, params, tmux_opts())
    socket = refresh(socket)
    show_result(socket, result_line(control, outcome, row))
  end

  defp run_control(socket, _, _), do: socket

  defp check_tmux(%{assigns: %{row: %{ended_at: nil} = row}} = socket) do
    opts = Keyword.put(tmux_opts(), :socket, SessionPane.socket(row.tmux_server))
    ok? = match?({:ok, _}, Foreman.SessionTargets.list(opts))

    {next, []} =
      SessionsConnection.step(socket.assigns.tmux, if(ok?, do: :read_ok, else: :read_failed), %{})

    assign(socket,
      tmux: next,
      tmux_at: if(ok?, do: DateTime.utc_now(), else: socket.assigns.tmux_at)
    )
  end

  defp check_tmux(socket), do: socket

  defp tmux_opts, do: Application.get_env(:foreman, :session_controls_tmux, [])

  defp message_form(text \\ "", error \\ nil) do
    errors = if error, do: [text: {error, []}], else: []
    to_form(%{"text" => text}, as: :message, errors: errors)
  end

  @verbs %{focus: "focus", continue: "continue", message: "send to", park: "park", stop: "stop"}

  # Result lines (Decision 17): the exact copy for each control, then the shared failure line.
  defp result_line(:focus, :ok, row), do: {:success, "Brought #{row.name} to the front."}

  defp result_line(:focus, {:ok, :no_client}, _),
    do: {:info, "No terminal is attached. Copy the attach command from Details."}

  defp result_line(:continue, :ok, row), do: {:success, ~s(Sent "continue" to #{row.name}.)}
  defp result_line(:message, :ok, row), do: {:success, "Sent to #{row.name}."}

  defp result_line(:park, :ok, row),
    do: {:success, "Parked #{row.name}. Its builds keep running."}

  defp result_line(:stop, :ok, row),
    do: {:success, "Stopped #{row.name}. The worktree and branch stay."}

  defp result_line(control, {:error, reason}, row),
    do: {:error, "Could not #{@verbs[control]} #{row.name}: #{failure(reason)}. Nothing changed."}

  defp failure(:tmux_unavailable), do: "tmux does not answer"
  defp failure(:window_gone), do: "the pane is closed"
  defp failure(:pane_changed), do: "the pane no longer runs this session"
  defp failure(:prompt_busy), do: "the agent is busy"
  defp failure(:invalid), do: "it is not available now"
  defp failure(:answer_required), do: "the message is empty"
  defp failure("refused in preview"), do: "this preview does not write to tmux"
  defp failure(_), do: "the board could not do it"

  def terminate(_reason, socket), do: read(socket, :closed)

  # What the page shows decides whether the pane is read (spec Decision 14).
  defp view_pane(%{assigns: %{row: row}} = socket) do
    if socket.assigns.connected and row do
      read(
        socket,
        {:view,
         %{
           live: is_nil(row.ended_at),
           shown: socket.assigns.tab == :output,
           visible: socket.assigns.visible
         }}
      )
    else
      socket
    end
  end

  defp view_pane(socket), do: socket

  defp read(socket, event) do
    case PaneReader.step(socket.assigns.reader, event, socket.assigns.reader_data) do
      {:error, _} -> socket
      {state, effects} -> Enum.reduce(effects, assign(socket, :reader, state), &reader_effect/2)
    end
  end

  defp reader_effect({:capture, :pane}, %{assigns: %{capturing: true}} = socket), do: socket

  defp reader_effect({:capture, :pane}, socket) do
    target = PaneCapture.target(socket.assigns.row)

    socket
    |> assign(:capturing, true)
    |> start_async(:pane_capture, fn -> PaneCapture.read(target) end)
  end

  defp reader_effect({:timer, kind}, socket) do
    socket = reader_effect({:cancel, :timer}, socket)
    delay = if kind == :retry, do: 5_000, else: 1_000
    assign(socket, :timer, Process.send_after(self(), :pane_tick, delay))
  end

  defp reader_effect({:cancel, :timer}, socket) do
    if socket.assigns.timer, do: Process.cancel_timer(socket.assigns.timer)
    assign(socket, :timer, nil)
  end

  defp reader_effect({:push, :output}, %{assigns: %{captured: {text, hash}}} = socket) do
    socket
    |> assign(shown: text, retry_result: nil)
    |> update(:reader_data, &%{&1 | hash: hash})
  end

  defp reader_effect({:push, :error}, socket), do: assign(socket, :retry_result, nil)

  defp reader_effect({:push, :still_down}, socket),
    do: assign(socket, :retry_result, "tmux still does not answer.")

  defp reader_effect({:save, :capture}, %{assigns: %{shown: text, row: row}} = socket)
       when is_binary(text) do
    at = DateTime.utc_now()

    case SessionCaptures.save(row.id, text, :poll, at) do
      {:ok, _} -> update(socket, :reader_data, &%{&1 | saved_hash: &1.hash, saved_at: at})
      _ -> socket
    end
  end

  defp reader_effect(_, socket), do: socket

  defp provider(cards) do
    case Enum.find(cards, &(&1.facts["reason"] == "usage_limit")) do
      nil -> "provider"
      card -> card.facts["provider"] || "provider"
    end
  end

  defp resume_reason(%{conversation_id: id}) when id in [nil, ""],
    do: "No Pi session id was recorded at launch."

  defp resume_reason(%{workdir: dir}) do
    if is_binary(dir) and File.dir?(dir),
      do: "The Pi session file is not available.",
      else: "The worktree was removed."
  end

  @buttons %{
    answer: {"Answer on the card", "hero-inbox", nil},
    continue: {"Continue", "hero-play", "Continuing…"},
    focus: {"Focus terminal", "hero-command-line", "Focusing…"},
    park: {"Park", "hero-pause", "Parking…"},
    retry: {"Try again now", "hero-arrow-path", "Trying…"},
    message: {"Send message", "hero-paper-airplane", "Sending…"},
    stop: {"Stop", "hero-stop", "Stopping…"}
  }

  # The one "Not available now:" line: off controls in page order, those with one reason
  # named together ("Focus terminal, Send message and Stop (The pane is closed.)").
  defp unavailable(controls) do
    controls
    |> Enum.flat_map(fn
      {control, {:off, reason}} -> [{elem(@buttons[control], 0), reason}]
      _ -> []
    end)
    |> Enum.chunk_by(&elem(&1, 1))
    |> Enum.map_join(" · ", fn [{_, reason} | _] = group ->
      names = Enum.map(group, &elem(&1, 0))

      case Enum.split(names, -1) do
        {[], [one]} -> one
        {rest, [last]} -> Enum.join(rest, ", ") <> " and " <> last
      end <> " (" <> reason <> ")"
    end)
  end

  defp on?(controls, control), do: List.keyfind(controls, control, 0) == {control, :on}

  # The next-step panel's one filled button (Decision 10).
  defp primary(row, controls, card) do
    cond do
      on?(controls, :retry) -> :retry
      row.state == "waiting.usage_limit" and on?(controls, :continue) -> :continue
      row.state == "waiting.permission" and on?(controls, :focus) -> :focus
      card -> :answer
      true -> nil
    end
  end

  attr :control, :atom, required: true
  attr :card, :map, default: nil
  attr :filled, :boolean, default: false

  # One control button; buttons size to their labels (Decision 17).
  defp control(assigns) do
    {label, icon, busy} = @buttons[assigns.control]
    assigns = assign(assigns, label: label, icon: icon, busy: busy)

    ~H"""
    <Button.button
      :if={@control == :answer}
      id={if(@filled, do: "session-answer", else: "session-control-answer")}
      size="sm"
      variant={if(@filled, do: "solid", else: "outline")}
      navigate={"/needs-you#request-#{@card.id}"}
      class="bb-session-control"
    >
      <.icon name={@icon} class="size-4" /> {@label}
    </Button.button>
    <Button.button
      :if={@control != :answer}
      id={"session-control-#{@control}"}
      type="button"
      size="sm"
      variant={if(@filled, do: "solid", else: "outline")}
      class="bb-session-control"
      phx-click={if(@control == :retry, do: "retry-tmux", else: "control")}
      phx-value-control={@control}
      phx-disable-with={@busy}
    >
      <.icon name={@icon} class="size-4" /> {@label}
    </Button.button>
    """
  end

  # tmux does not answer: the last label, with when it was last read.
  defp not_checked(view, nil), do: view

  defp not_checked(view, at),
    do: %{view | second: "not checked since " <> RelativeTime.format(at), at: at}

  @saved_lines %{
    "exit" => ", when the pane closed",
    "poll" => " from the last check",
    "stop" => ", when you pressed Stop",
    "park" => ", when the session was parked"
  }

  attr :row, :map, required: true
  attr :reader, :atom, required: true
  attr :shown, :string, doc: "the last capture shown, raw"
  attr :saved, :map, doc: "the session_captures row of a dead session"
  attr :retry_result, :string

  # Recent output (spec Decisions 14-15): live while the pane exists, saved after.
  defp output(%{row: %{ended_at: nil}} = assigns) do
    ~H"""
    <section
      id="session-output"
      phx-hook=".PaneOutput"
      class={["bb-term", @reader in [:tmux_error, :retrying] && "bb-term-stale"]}
    >
      <div :if={@reader in [:tmux_error, :retrying]} id="session-output-head" class="bb-term-head">
        <span class="bb-dot bb-term-warn" aria-hidden="true"></span>
        <span id="session-output-error">Cannot read the terminal: tmux does not answer.</span>
        <span :if={@retry_result} id="session-output-retry-result">{@retry_result}</span>
        <button
          id="session-output-retry"
          type="button"
          phx-click="retry-output"
          phx-disable-with="Trying…"
          class="bb-term-btn"
        >
          Try again now
        </button>
      </div>
      <%= cond do %>
        <% is_nil(@shown) and @reader not in [:tmux_error, :retrying] -> %>
          <div id="session-output-loading" class="bb-term-pad" aria-busy="true">
            <p class="bb-term-note">Reading the terminal…</p>
            <span
              :for={width <- [80, 64, 72, 40, 90, 55]}
              class="bb-skel bb-term-skel"
              style={"width: #{width}%"}
            >
            </span>
          </div>
        <% is_nil(@shown) -> %>
        <% AnsiHtml.blank?(@shown) -> %>
          <p id="session-output-empty" class="bb-term-pad bb-term-note">No output yet.</p>
        <% true -> %>
          <pre
            id="session-output-body"
            class="bb-term-body"
            tabindex="0"
            aria-label="Recent output"
            data-scroll-end
          >{AnsiHtml.to_html(@shown)}</pre>
      <% end %>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".PaneOutput">
        export default {
          mounted() {
            this.onVisibility = () =>
              this.pushEvent("output-visibility", {visible: document.visibilityState === "visible"})
            document.addEventListener("visibilitychange", this.onVisibility)
            this.onVisibility()
            this.pin()
          },
          reconnected() { this.onVisibility() },
          beforeUpdate() {
            const body = this.body()
            this.atEnd = !body || body.scrollHeight - body.scrollTop - body.clientHeight < 24
          },
          updated() { if (this.atEnd) this.pin() },
          destroyed() { document.removeEventListener("visibilitychange", this.onVisibility) },
          body() { return this.el.querySelector("[data-scroll-end]") },
          pin() {
            const body = this.body()
            if (body) body.scrollTop = body.scrollHeight
          }
        }
      </script>
    </section>
    """
  end

  defp output(assigns) do
    assigns = assign(assigns, :saved_line, assigns.saved && @saved_lines[assigns.saved.reason])

    ~H"""
    <section id="session-output" phx-hook=".PaneOutput" class="bb-term">
      <%= if @saved && !AnsiHtml.blank?(@saved.output) do %>
        <div id="session-output-head" class="bb-term-head">
          <span class="bb-dot bb-dot-off" aria-hidden="true"></span>
          <span>Saved <.timestamp at={@saved.captured_at} />{@saved_line}</span>
        </div>
        <pre
          id="session-output-body"
          class="bb-term-body"
          tabindex="0"
          aria-label="Recent output"
          data-scroll-end
        >{AnsiHtml.to_html(@saved.output)}</pre>
      <% else %>
        <p id="session-output-empty" class="bb-term-pad bb-term-note">
          No output was saved for this session.
        </p>
      <% end %>
    </section>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:sessions}
      repos={@repos}
      pending_count={@pending_count}
      drawer_state={@drawer_state}
      streams={@streams}
    >
      <div class="bb-session-page max-w-3xl space-y-6">
        <ForemanWeb.StatusLine.status_line
          id="session-disconnected"
          kind={:info}
          class="bb-session-offline"
        >
          Not connected. Trying again…
        </ForemanWeb.StatusLine.status_line>
        <nav
          id="session-breadcrumb"
          aria-label="Breadcrumb"
          class="flex flex-wrap items-center gap-2 text-xs text-foreground-softer"
        >
          <.link navigate="/sessions">Sessions</.link>
          <%= if @parent do %>
            <span>/</span><.link navigate={"/sessions/#{@parent.id}"} class="font-mono">{@parent.name}</.link>
          <% end %>
          <%= if @row do %>
            <span>/</span><span class="font-mono">{@row.name}</span>
          <% end %>
        </nav>
        <%= if @row do %>
          <header class="space-y-3">
            <h1 id="session-heading" class="text-xl font-semibold">{@title}</h1>
            <div class="flex flex-wrap items-center gap-3 text-xs text-foreground-softer">
              <SessionState.badge
                :if={!@tmux_down}
                id="session-state"
                view={@state}
              />
              <span :if={@tmux_down} class="bb-session-stale">
                <SessionState.badge
                  id="session-state"
                  view={not_checked(@state, @tmux_at || @row.last_seen_at || @row.started_at)}
                />
              </span>
              <span class="font-mono">{@row.name}</span><span>{@source.role}</span>
              <span :if={is_nil(@row.ended_at)} id="session-live-line" class="bb-session-live">
                <%= if @connected do %>
                  <span class="bb-dot mr-1" aria-hidden="true"></span>Live · updated
                  <.timestamp at={@row.last_seen_at || @row.started_at} />
                <% else %>
                  <span class="bb-dot bb-dot-grey mr-1" aria-hidden="true"></span>Connecting…
                <% end %>
              </span>
            </div>
          </header>
          <section id="session-next-step" class="bb-panel space-y-2">
            <%= cond do %>
              <% @tmux_down -> %>
                <h2 class="font-semibold">The board cannot reach tmux.</h2>
                <p>
                  The session can still run. The label and output are from
                  <.timestamp at={@tmux_at || @row.last_seen_at || @row.started_at} />.
                </p>
              <% @row.ended_at && @card -> %>
                <h2 class="font-semibold">Its question is still open.</h2>
                <p>{@card.facts["question"]}</p>
              <% @row.state == "parked" -> %>
                <h2 class="font-semibold">Parked <.timestamp at={@row.ended_at} />.</h2>
                <p>Its builds keep running.</p>
              <% @row.ended_at -> %>
                <h2 class="font-semibold">
                  Ended
                  <.timestamp at={@row.ended_at} />{if !@resumable && @row.kind == "build",
                    do: " during round #{@round}"}.
                </h2>
                <p :if={@resumable}>The pane is closed.</p>
                <p :if={@parent && @parent.ended_at}>
                  {@parent.name} ended <.timestamp at={@parent.ended_at} /> too.
                </p>
                <p :if={!@resumable && @row.kind != "build"}>
                  The board has no conversation id for it.
                </p>
                <p :if={!@resumable && @row.kind == "build"}>
                  This build cannot resume: {resume_reason(@row)}
                </p>
              <% @row.state == "waiting.permission" -> %>
                <h2 class="font-semibold">It waits for a permission answer in the terminal.</h2>
              <% @row.state == "waiting.usage_limit" -> %>
                <h2 class="font-semibold">Stopped at the {@provider} usage limit.</h2>
                <p :if={@state.second} title={@state.at && DateTime.to_iso8601(@state.at)}>
                  {@state.second}
                </p>
              <% @state.label == "Waiting on you" -> %>
                <h2 class="font-semibold">It asked you a question.</h2>
                <p :if={@card}>{@card.facts["question"]}</p>
              <% @state.label == "In review" -> %>
                <h2 class="font-semibold">
                  {if @parent, do: @parent.name, else: "The coordinator"} reviews round {@round}.
                </h2>
                <p>Nothing waits on you.</p>
              <% @state.label == "Idle" -> %>
                <h2 class="font-semibold">Idle.</h2>
                <p>Nothing waits on you.</p>
              <% @row.kind != "build" -> %>
                <h2 class="font-semibold">Working.</h2>
                <p>Nothing waits on you.</p>
              <% true -> %>
                <h2 class="font-semibold">Working on round {@round}.</h2>
                <p>Nothing waits on you.</p>
            <% end %>
            <.control
              :if={@primary}
              control={@primary}
              card={@card}
              filled
            />
          </section>
          <div :if={@row_controls != [] or @stop} id="session-controls" class="bb-session-controls">
            <.control :for={control <- @row_controls} control={control} card={@card} />
            <Button.button
              :if={@stop}
              id="session-stop"
              type="button"
              size="sm"
              variant="outline"
              class="bb-session-stop"
              phx-click="ask-stop"
              aria-expanded={to_string(@panel == :confirming)}
              aria-controls="session-stop-confirm"
            >
              <.icon name="hero-stop" class="size-4" /> Stop
            </Button.button>
          </div>
          <section
            :if={@panel == :confirming}
            id="session-stop-confirm"
            role="alertdialog"
            aria-labelledby="session-stop-question"
            class="bb-panel bb-session-confirm space-y-3"
          >
            <h2 id="session-stop-question" class="font-semibold">Stop {@row.name}?</h2>
            <p class="text-sm">
              The agent stops now and loses work it has not saved.
              <%= cond do %>
                <% @row.workdir && @row.branch -> %>
                  The worktree <span class="font-mono">{@row.workdir}</span>
                  and the branch <span class="font-mono">{@row.branch}</span>
                  stay.
                <% @row.workdir -> %>
                  The worktree <span class="font-mono">{@row.workdir}</span> stays.
                <% @row.branch -> %>
                  The branch <span class="font-mono">{@row.branch}</span> stays.
                <% true -> %>
              <% end %>
              {if @row.kind != "build", do: "Its builds keep running."}
            </p>
            <div class="bb-session-controls">
              <Button.button
                id="session-stop-confirm-yes"
                type="button"
                size="sm"
                variant="solid"
                color="danger"
                phx-click="stop"
                phx-disable-with="Stopping…"
              >
                Stop session
              </Button.button>
              <Button.button
                id="session-stop-keep"
                type="button"
                size="sm"
                variant="outline"
                phx-click="keep-running"
                phx-mounted={JS.focus()}
              >
                Keep it running
              </Button.button>
            </div>
          </section>
          <ForemanWeb.StatusLine.status_line
            :if={@result}
            id="session-result"
            kind={elem(@result, 0)}
          >
            {elem(@result, 1)}
          </ForemanWeb.StatusLine.status_line>
          <.form
            :if={on?(@controls, :message)}
            for={@message_form}
            id="session-message-form"
            phx-submit="send-message"
            class="bb-session-message"
          >
            <div class="min-w-0 flex-1">
              <.input
                field={@message_form[:text]}
                id={"session-message-text-#{@sent}"}
                label={"Message to #{@row.name}"}
                autocomplete="off"
                class="w-full rounded-md border border-base bg-base px-3 py-2 text-sm focus:outline-primary"
              />
            </div>
            <Button.button
              id="session-message-send"
              type="submit"
              size="sm"
              variant="outline"
              phx-disable-with="Sending…"
            >
              <.icon name="hero-paper-airplane" class="size-4" /> Send
            </Button.button>
          </.form>
          <p
            :if={@unavailable != ""}
            id="session-unavailable"
            class="text-xs text-foreground-softer"
          >
            Not available now: {@unavailable}
          </p>
          <nav aria-label="Session tabs" class="flex gap-5 border-b border-base">
            <.link
              :for={
                {tab, label} <- [
                  {:output, "Recent output"},
                  {:timeline, "Timeline"},
                  {:details, "Details"}
                ]
              }
              id={"session-tab-#{tab}"}
              patch={"/sessions/#{@row.id}?tab=#{tab}"}
              aria-current={@tab == tab && "page"}
              class={["pb-3 text-sm", @tab == tab && "border-b-2 border-foreground font-medium"]}
            >
              {label}
            </.link>
          </nav>
          <.output
            :if={@tab == :output}
            row={@row}
            reader={@reader}
            shown={@shown}
            saved={@saved}
            retry_result={@retry_result}
          />
          <section :if={@tab == :timeline} id="session-timeline">
            <div id="session-rounds" phx-update="stream" class="space-y-3">
              <p id="session-no-events" class="hidden only:block text-foreground-softer">
                No events yet.
              </p>
              <section :for={{id, round} <- @streams.rounds} id={id} class="bb-panel">
                <button
                  :if={round.grouped}
                  id={"session-round-#{round.id}-toggle"}
                  type="button"
                  phx-click="toggle-round"
                  phx-value-round={round.id}
                  aria-expanded={to_string(round.open)}
                  aria-controls={"session-round-#{round.id}-events"}
                  class="flex w-full items-center gap-2 text-left font-medium"
                >
                  <.icon
                    name={if(round.open, do: "hero-chevron-down", else: "hero-chevron-right")}
                    class="size-4"
                  /> Round {round.id}
                </button>
                <ol
                  :if={round.open or not round.grouped}
                  id={"session-round-#{round.id}-events"}
                  class={["space-y-4 border-l border-base pl-5", round.grouped && "mt-4"]}
                >
                  <li :for={event <- round.events} id={"session-event-#{event.id}"} class="space-y-1">
                    <div class="flex flex-wrap items-center gap-3">
                      <span class="font-medium">{event.label}</span><span class="text-xs text-foreground-softer"><.timestamp at={
                        event.at
                      } /></span>
                    </div>
                    <p :if={event.text} class="text-sm">
                      <ForemanWeb.LongText.path text={event.text} class="whitespace-pre-line" />
                    </p>
                    <.link :if={event.href} navigate={event.href} class="text-xs underline">
                      Open card
                    </.link>
                  </li>
                </ol>
              </section>
            </div>
          </section>
          <section :if={@tab == :details} id="session-details" class="bb-panel space-y-5">
            <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-6 gap-y-3 text-sm">
              <%= for {key, label} <- [harness: "Harness", model: "Model", project: "Project", ticket: "Ticket", branch: "Branch", workdir: "Workdir", tmux_server: "Server", pane_id: "Pane", conversation_id: "Conversation id"] do %>
                <dt class="text-foreground-softer">{label}</dt>
                <dd class="min-w-0 font-mono">
                  <ForemanWeb.LongText.path text={Map.get(@row, key) || "—"} />
                </dd>
              <% end %>
              <%= for {key, label} <- [started_at: "Started", last_seen_at: "Last seen", ended_at: "Ended"] do %>
                <dt class="text-foreground-softer">{label}</dt>
                <dd><.timestamp at={Map.get(@row, key)} /></dd>
              <% end %>
            </dl>
            <ForemanWeb.CopyField.copy_field
              id="session-attach"
              label="Attach command"
              value={RequestSource.command(@source.source)}
            />
          </section>
        <% else %>
          <p id="session-unknown">The board has no session with this id.</p>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
