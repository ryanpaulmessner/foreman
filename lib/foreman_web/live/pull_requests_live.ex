defmodule ForemanWeb.PullRequestsLive do
  use ForemanWeb, :live_view
  alias Fluxon.Components.{Badge, Button, Modal}
  alias Foreman.Merge
  alias Foreman.Merge.Action

  @impl true
  def mount(_, _, socket) do
    if connected?(socket) do
      Foreman.Events.subscribe()
      Process.send_after(self(), :reconcile, 3_000)
    end

    {:ok,
     assign(socket,
       project: nil,
       refresh_state: :idle,
       merge_state: :idle,
       merge_facts: nil,
       merge_remote: nil,
       merge_message: nil,
       merge_record: nil,
       approval_request: nil,
       approval_note: nil
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {state, []} = Foreman.Forge.RefreshStatus.step(socket.assigns.refresh_state, :cancel, %{})
    socket = socket |> assign(refresh_state: state) |> clear_flash(:info)

    socket =
      if params["project"] != socket.assigns.project,
        do:
          assign(socket,
            merge_state: :idle,
            merge_facts: nil,
            merge_message: nil,
            merge_record: nil
          ),
        else: socket

    {:noreply,
     socket
     |> assign(project: params["project"])
     |> ForemanWeb.TicketDetail.load(params, uri)
     |> refresh()
     |> open_approval(params)}
  end

  defp open_approval(socket, %{"request" => id}) do
    case Foreman.Requests.get(id) do
      %{kind: "merge", state: "pending", repo_key: key} = request
      when key == socket.assigns.project ->
        case Foreman.Requests.resolve(id, :approve, %{}) do
          {:error, :confirmation_required} ->
            socket = assign(socket, approval_request: id, approval_note: request.note)

            {:noreply, socket} =
              handle_event(
                "merge-request",
                %{"number" => to_string(request.facts["number"])},
                socket
              )

            socket

          _ ->
            assign(socket, merge_message: "Request superseded")
        end

      _ ->
        assign(socket, merge_message: "Request unavailable")
    end
  end

  defp open_approval(socket, _), do: assign(socket, approval_request: nil, approval_note: nil)

  @impl true
  def handle_info(:reconcile, socket) do
    Process.send_after(self(), :reconcile, 3_000)
    {:noreply, refresh(socket)}
  end

  def handle_info({:notification, :foreman_events, _}, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_event("refresh", _, socket) do
    {state, [status: :refreshing]} =
      Foreman.Forge.RefreshStatus.step(socket.assigns.refresh_state, :request, %{})

    socket = socket |> assign(refresh_state: state) |> put_flash(:info, "Refreshing")

    if socket.assigns.panel && Foreman.Forge.SyncJob.due?(socket.assigns.stored, true) do
      Foreman.Events.broadcast(:forge_requested, socket.assigns.project)
      {:noreply, socket}
    else
      status =
        case socket.assigns.stored do
          %{error: "rate_limited"} -> "Rate limited"
          %{error: error} when not is_nil(error) -> "Refresh failed"
          _ -> "Up to date"
        end

      {:noreply, finish_refresh(socket, status)}
    end
  end

  def handle_event("merge-request", _, %{assigns: %{human_merge: true}} = socket),
    do: {:noreply, assign(socket, merge_message: "Merge unavailable")}

  def handle_event("merge-request", %{"number" => number}, socket) do
    parsed = Integer.parse(number)

    result =
      with {n, ""} <- parsed,
           %{snapshot: snapshot} <- socket.assigns.stored,
           do: Merge.prepare(snapshot, n)

    case result do
      {:ok, facts} ->
        case Action.step(
               socket.assigns.merge_state,
               :request,
               Merge.data(facts, socket.assigns.capabilities)
             ) do
          {:confirming, []} ->
            prior =
              Merge.attempt(
                socket.assigns.stored.remote,
                facts["pr"]["number"],
                facts["pr"]["head_sha"]
              )

            if prior && is_nil(socket.assigns.approval_request) do
              {:noreply,
               assign(socket,
                 merge_state: merge_state(prior.state),
                 merge_facts: nil,
                 merge_record: prior,
                 merge_message: record_label(prior)
               )}
            else
              {:noreply,
               assign(socket,
                 merge_state: :confirming,
                 merge_facts: facts,
                 merge_remote: socket.assigns.stored.remote,
                 merge_message: nil
               )}
            end

          _ ->
            {:noreply, assign(socket, merge_message: "Merge unavailable")}
        end

      {:error, reason} ->
        {:noreply, assign(socket, merge_message: reason_label(reason))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("merge-cancel", _, socket) do
    case Action.step(socket.assigns.merge_state, :cancel, %{}) do
      {:idle, []} ->
        {:noreply,
         socket
         |> assign(merge_state: :idle, merge_facts: nil, merge_message: nil)
         |> close_approval_route()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("merge-confirm", _, %{assigns: %{merge_state: :confirming}} = socket) do
    facts = socket.assigns.merge_facts
    current = Foreman.Forge.Store.get(socket.assigns.project)

    unchanged =
      current && current.remote == socket.assigns.merge_remote &&
        Enum.any?(
          current.snapshot["change_requests"] || [],
          &(&1["number"] == facts["pr"]["number"] && &1["head_sha"] == facts["pr"]["head_sha"])
        )

    data = %{Merge.data(facts, socket.assigns.capabilities) | head_unchanged: !!unchanged}

    case Action.step(:confirming, :confirm, data) do
      {:merging, _} ->
        result =
          if socket.assigns.approval_request do
            case Foreman.Requests.confirm_merge(
                   socket.assigns.approval_request,
                   facts,
                   socket.assigns.approval_note
                 ) do
              {:ok, %{state: "executing"} = request} ->
                {:ok, Merge.get(request.outcome["result"]["action_id"])}

              _ ->
                {:error, :request_unavailable}
            end
          else
            Merge.enqueue(socket.assigns.project, socket.assigns.merge_remote, facts)
          end

        case result do
          {:ok, row} ->
            {:noreply,
             socket
             |> assign(merge_state: :merging, merge_facts: nil, merge_record: row)
             |> refresh()
             |> close_approval_route()}

          {:error, _} ->
            {:noreply, assign(socket, merge_message: "Merge unavailable")}
        end

      _ ->
        {:noreply, assign(socket, merge_message: "Head moved · Reopen confirmation")}
    end
  end

  def handle_event("merge-confirm", _, socket), do: {:noreply, socket}

  def handle_event("launch-session", params, socket),
    do: {:noreply, socket |> ForemanWeb.PlanningSession.launch(params) |> refresh()}

  def handle_event("preview", params, socket),
    do: {:noreply, ForemanWeb.TicketDetail.preview(socket, params)}

  def handle_event("close-ticket", params, socket),
    do: {:noreply, ForemanWeb.TicketDetail.close(socket, params)}

  def handle_event("ticket-priority", params, socket),
    do: {:noreply, socket |> ForemanWeb.TicketDetail.priority(params) |> refresh()}

  def handle_event("ticket-jump", params, socket),
    do: {:noreply, socket |> ForemanWeb.TicketDetail.jump(params) |> refresh()}

  defp close_approval_route(socket) do
    if socket.assigns.approval_request do
      socket
      |> assign(approval_request: nil, approval_note: nil)
      |> push_patch(to: ~p"/pull-requests?project=#{socket.assigns.project}")
    else
      socket
    end
  end

  defp refresh(socket) do
    repos = Foreman.RuntimeState.repos()
    project = socket.assigns.project || (Enum.find(repos, &remote?/1) || %{})["key"]
    repo = Enum.find(repos, &(&1["key"] == project))
    panel = repo && remote?(repo)
    stored = if panel, do: Foreman.Forge.Store.get(project)
    stored = if stored && stored.remote == repo["github"], do: stored
    snapshot = (stored && stored.snapshot) || %{}
    human? = Foreman.MergePolicy.human?(repo)

    # Human-merge repos stack on their configured base (ReportSystem: staging), not the
    # forge default branch; board-merge repos keep the default branch.
    stack_base =
      if human?,
        do: Foreman.MergePolicy.base(repo, snapshot["default_branch"]),
        else: snapshot["default_branch"]

    prs = Foreman.Forge.Stack.order(snapshot["change_requests"] || [], stack_base)
    previous = Map.get(socket.assigns, :stored)

    socket =
      if stored && (!previous || stored.attempted_at != previous.attempted_at) do
        finish_refresh(socket, if(stored.error, do: "Refresh failed", else: "Updated"))
      else
        socket
      end

    record = if project, do: Merge.latest(project)
    record = if record && repo && record.remote == repo["github"], do: record

    socket =
      if record && socket.assigns.merge_state != :confirming do
        assign(socket,
          merge_record: record,
          merge_state: merge_state(record.state),
          merge_message: record_label(record)
        )
      else
        socket
      end

    socket
    |> assign(
      capabilities: Foreman.Forge.adapter().capabilities(),
      repos: repos,
      project: project,
      panel: panel,
      stored: stored,
      default_branch: stack_base,
      human_merge: human?,
      count: length(prs)
    )
    |> stream(:projects, Enum.map(repos, &%{id: &1["key"], repo: &1}), reset: true)
    |> stream(:prs, Enum.map(prs, &Map.put(&1, :id, "cr-#{project}-#{&1["number"]}")),
      reset: true,
      dom_id: & &1.id
    )
    |> ForemanWeb.TicketDetail.refresh()
  end

  defp finish_refresh(socket, status) do
    {state, effects} =
      Foreman.Forge.RefreshStatus.step(socket.assigns.refresh_state, :complete, %{})

    socket = assign(socket, refresh_state: state)
    if effects == [status: :result], do: put_flash(socket, :info, status), else: socket
  end

  # A detached stack root's parent was merged (or closed) on GitHub; its children still
  # wait on it. Foreman never retargets in a human-merge repo.
  defp manual_retarget?(pr), do: pr["detached"] == true and is_nil(pr["parent"])

  defp remote?(repo),
    do: repo["enabled"] && repo["forge"] == "github" && is_binary(repo["github"])

  defp status(%{"detached" => true}), do: "Detached base"
  defp status(%{"parent" => parent}) when not is_nil(parent), do: "Waiting on ##{parent}"
  defp status(%{"draft" => true}), do: "Draft"
  defp status(%{"mergeable" => "conflicting"}), do: "Conflicts"

  defp status(%{"checks" => checks}) when checks not in ["success", "none"],
    do: "Checks: #{checks}"

  defp status(%{"mergeable" => "mergeable"}), do: "Ready"
  defp status(_), do: "Mergeability unknown"

  defp merge_state(state), do: Enum.find(Action.__fsm__(:states), &(Atom.to_string(&1) == state))
  defp reason_label(:not_bottom), do: "Bottom of stack only"
  defp reason_label(:head_moved), do: "Head moved"
  defp reason_label(:not_mergeable), do: "Not mergeable"

  defp reason_label(reason),
    do: reason |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp record_label(%{state: "merging"}), do: "Merging"

  defp record_label(%{state: "retargeting", facts: facts}),
    do: "Retargeting ##{facts["child"]["number"]}"

  defp record_label(%{state: "merged", error: nil}), do: "Merged"

  defp record_label(%{merge_sha: sha, facts: facts}) when not is_nil(sha),
    do: "Merged · Manual retarget ##{facts["child"]["number"]} → #{facts["default_branch"]}"

  defp record_label(%{error: "outcome_unknown"}), do: "Outcome unknown · Check forge"
  defp record_label(%{error: error}), do: "Merge failed · #{reason_label(error)}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      drawer_state={@drawer_state}
      drawer_error={@drawer_error}
      streams={@streams}
      flash={@flash}
      pending_count={@pending_count}
      active={:pull_requests}
      repos={@repos}
    >
      <header class="flex flex-wrap items-center gap-3">
        <div class="mr-auto space-y-1">
          <h1 class="text-[22px] leading-7 font-semibold">Pull requests</h1>
        </div>
        <Button.button :if={@panel} id="forge-refresh" phx-click="refresh" variant="outline" size="sm">
          <.icon name="hero-arrow-path" class="size-4" /> Refresh
        </Button.button>
      </header>
      <nav
        id="forge-projects"
        phx-update="stream"
        class="flex flex-wrap gap-x-5 border-b border-base"
        aria-label="Pull request projects"
      >
        <.link
          :for={{id, item} <- @streams.projects}
          id={id}
          patch={~p"/pull-requests?project=#{item.repo["key"]}"}
          class={[
            "flex items-center gap-2 border-b-2 py-3 text-sm",
            if(@project == item.repo["key"],
              do: "border-primary font-medium",
              else: "border-transparent text-foreground-softer"
            )
          ]}
          aria-current={@project == item.repo["key"] && "page"}
        >
          {item.repo["key"]}
          <span :if={!remote?(item.repo)} class="text-xs">no remote</span>
        </.link>
      </nav>
      <section :if={@panel} id="forge-panel" class="space-y-4">
        <div class="flex flex-wrap items-center gap-3 text-xs text-foreground-softer">
          <span class="bb-label">Stack on {@default_branch || "default branch"}</span>
          <Badge.badge :if={@default_branch} class="font-mono">{@default_branch}</Badge.badge>
          <span>{@count} open</span>
          <span :if={@stored && @stored.synced_at} id="forge-synced" class="ml-auto">
            Synced <ForemanWeb.TicketDetail.timestamp at={@stored.synced_at} />
          </span>
        </div>
        <div :if={!@stored} id="forge-waiting" class="bb-panel text-foreground-softer">
          Awaiting sync
        </div>
        <div
          :if={@stored && @stored.error}
          id="forge-error"
          role="status"
          class="bb-panel text-foreground-softer"
        >
          Sync failed · {@stored.error}
        </div>
        <div
          :if={@merge_message}
          id="merge-status"
          role="status"
          data-state={@merge_state}
          class="bb-panel flex flex-wrap items-center gap-3 text-sm"
        >
          <.icon
            :if={@merge_state in [:merging, :retargeting]}
            name="hero-arrow-path"
            class="size-4 animate-spin"
          />
          {@merge_message}
          <span :if={@merge_record} class="ml-auto text-xs text-foreground-softer">
            <ForemanWeb.TicketDetail.timestamp at={@merge_record.updated_at} />
          </span>
        </div>
        <div id="pull-requests" phx-update="stream" class="space-y-3">
          <div
            id="prs-empty"
            class="hidden rounded-xl border border-base p-8 text-center text-foreground-softer only:block"
          >
            No open pull requests
          </div>
          <article
            :for={{id, pr} <- @streams.prs}
            id={id}
            data-number={pr["number"]}
            class="flex gap-3"
            style={"padding-left: #{min(pr["depth"], 5) * 28}px"}
          >
            <div
              aria-hidden="true"
              class="mt-1 h-10 w-4 shrink-0 rounded-bl-lg border-b-2 border-l-2 border-base"
            >
            </div>
            <div class="bb-panel flex min-w-0 flex-1 flex-wrap items-center gap-4 !p-4">
              <div class="w-full min-w-0 space-y-2 md:w-auto md:flex-1">
                <a
                  href={pr["url"]}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="block font-medium break-words hover:underline"
                >
                  <span class="mr-2 font-mono text-xs text-foreground-softer">#{pr["number"]}</span>{pr[
                    "title"
                  ]}
                </a>
                <div class="flex flex-wrap items-center gap-1.5">
                  <Badge.badge class="max-w-full font-mono">
                    <span class="truncate">{pr["source_branch"]} → {pr["target_branch"]}</span>
                  </Badge.badge>
                  <Badge.badge class="font-mono">
                    {String.slice(pr["head_sha"] || "", 0, 7)}
                  </Badge.badge>
                  <Badge.badge>checks: {pr["checks"]}</Badge.badge>
                  <.link
                    :for={link <- pr["links"] || []}
                    patch={Foreman.TicketSheet.path(@page_uri, {@project, link["bead_id"]})}
                    data-bead={link["bead_id"]}
                    title={"Source: #{link["source"]}"}
                  >
                    <Badge.badge color="info" class="font-mono">{link["bead_id"]}</Badge.badge>
                  </.link>
                </div>
              </div>
              <span data-parent={pr["parent"]}>
                <Badge.badge>{status(pr)}</Badge.badge>
              </span>
              <div
                :if={@human_merge}
                id={"human-merge-#{pr["number"]}"}
                class="flex flex-col items-start gap-1 text-xs text-foreground-softer md:items-end"
              >
                <span :if={!manual_retarget?(pr)} data-role="waiting">
                  Waiting for a person to merge on GitHub
                </span>
                <span :if={manual_retarget?(pr)} data-role="manual-retarget">
                  Retarget onto {@default_branch} on GitHub
                </span>
                <a
                  id={"pr-link-#{pr["number"]}"}
                  href={pr["url"]}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="inline-flex items-center gap-1 font-medium text-foreground hover:underline"
                >
                  Open on GitHub <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
                </a>
              </div>
              <Button.button
                :if={@capabilities.write && !@human_merge}
                id={"merge-request-#{pr["number"]}"}
                phx-click="merge-request"
                phx-value-number={pr["number"]}
                disabled={@merge_state in [:confirming, :merging, :retargeting]}
                variant="outline"
                size="sm"
              >
                Merge
              </Button.button>
            </div>
          </article>
        </div>
      </section>
      <p :if={!@panel} id="forge-no-remote" class="text-foreground-softer">
        No remote
      </p>
      <Modal.modal
        id="merge-confirm"
        open={@merge_state == :confirming}
        on_close={JS.push("merge-cancel")}
        class="w-[min(540px,calc(100vw-2rem))] space-y-5"
      >
        <%= if @merge_facts do %>
          <h2
            id="merge-confirm-title"
            class="text-lg font-semibold"
            phx-mounted={
              JS.set_attribute({"aria-labelledby", "merge-confirm-title"},
                to: "#merge-confirm [role=dialog]"
              )
            }
          >
            Merge pull request
          </h2>
          <div class="font-medium">
            #{@merge_facts["pr"]["number"]} · {@merge_facts["pr"]["title"]}
          </div>
          <dl class="grid grid-cols-[80px_minmax(0,1fr)] gap-x-4 gap-y-3 text-sm">
            <dt class="text-foreground-softer">Target</dt>
            <dd class="font-mono">{@merge_facts["default_branch"]}</dd>
            <dt class="text-foreground-softer">Head</dt>
            <dd class="break-all font-mono text-xs">{@merge_facts["pr"]["head_sha"]}</dd>
            <dt class="text-foreground-softer">Method</dt>
            <dd>Merge commit</dd>
            <dt class="text-foreground-softer">Tickets</dt>
            <dd class="flex flex-wrap gap-1">
              <Badge.badge :for={link <- @merge_facts["pr"]["links"] || []}>
                {link["bead_id"]}
              </Badge.badge>
            </dd>
            <dt class="text-foreground-softer">Guard</dt>
            <dd>
              {if @capabilities.head_guard, do: "Expected head SHA", else: "Weaker · Head re-read"}
            </dd>
            <dt :if={@merge_facts["child"]} class="text-foreground-softer">Then</dt>
            <dd :if={@merge_facts["child"]}>
              {if @capabilities.retarget, do: "Retarget", else: "Manual retarget"} #{@merge_facts[
                "child"
              ]["number"]} · {@merge_facts["child"]["target_branch"]} → {@merge_facts[
                "default_branch"
              ]}
            </dd>
          </dl>
          <div :if={@merge_message} role="status" class="text-sm">{@merge_message}</div>
          <div class="flex justify-end gap-2">
            <Button.button id="merge-confirm-cancel" phx-click="merge-cancel" variant="outline">
              Cancel
            </Button.button>
            <Button.button
              id="merge-confirm-submit"
              phx-click="merge-confirm"
              phx-disable-with="Merging"
              variant="solid"
              color="primary"
            >
              Merge pull request
            </Button.button>
          </div>
        <% end %>
      </Modal.modal>
      <ForemanWeb.TicketDetail.sheet
        ticket={@ticket}
        state={@sheet_state}
        tab={@ticket_tab}
        uri={@page_uri}
        return_to={@sheet_return}
        streams={@streams}
      />
    </Layouts.app>
    """
  end
end
