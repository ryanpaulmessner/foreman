defmodule ForemanWeb.WeekLive do
  use ForemanWeb, :live_view
  alias Foreman.Initiatives.Disclosure

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh_week, 30_000)
    {:ok, socket |> assign(:disclosures, %{}) |> refresh()}
  end

  @impl true
  def handle_info(:refresh_week, socket) do
    Process.send_after(self(), :refresh_week, 30_000)
    {:noreply, refresh(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle-week-ticket", %{"key" => key}, socket) do
    {state, []} =
      Disclosure.step(Map.get(socket.assigns.disclosures, key, :collapsed), :toggle, %{})

    {:noreply,
     socket |> assign(:disclosures, Map.put(socket.assigns.disclosures, key, state)) |> refresh()}
  end

  defp refresh(socket) do
    model = Foreman.Week.snapshot()

    keys =
      for section <- model.sections,
          group <- section.groups,
          item <- group.items,
          do: item_key(item)

    socket
    |> assign(:week, model.window)
    |> assign(:disclosures, Map.take(socket.assigns.disclosures, keys))
    |> stream(:sections, model.sections, reset: true, dom_id: &"week-#{&1.id}")
  end

  defp item_key(item), do: "#{item.repo}-#{item.id}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:week}>
      <div class="mx-auto w-full max-w-5xl p-4 sm:p-8">
        <header class="mb-8 flex flex-wrap items-baseline justify-between gap-2">
          <h1 class="text-2xl font-semibold tracking-tight">This week</h1>
          <p id="week-dates" class="text-sm text-foreground-softer">
            {Calendar.strftime(@week.first_date, "%b %-d")} – {Calendar.strftime(
              @week.last_date,
              "%b %-d, %Y"
            )}
          </p>
        </header>
        <div id="week-sections" phx-update="stream" class="space-y-8">
          <p
            id="week-empty"
            class="hidden only:block rounded-lg border border-base p-6 text-foreground-softer"
          >
            No work this week
          </p>
          <section
            :for={{dom_id, section} <- @streams.sections}
            id={dom_id}
            aria-label={section.label}
          >
            <h2 class="mb-4 flex items-center gap-3 text-lg font-semibold">
              {section.label}<span class="text-sm font-normal text-foreground-softer">{section.count}</span>
            </h2>
            <div :for={group <- section.groups} id={"week-group-#{group.id}"} class="mb-5">
              <h3 :if={group.epic_title} class="mb-2 font-medium">{group.epic_title}</h3>
              <h4 class="mb-2 text-xs font-medium text-foreground-softer">{group.stage}</h4>
              <div class="divide-y divide-base overflow-hidden rounded-lg border border-base">
                <article :for={item <- group.items} id={"week-ticket-#{item_key(item)}"}>
                  <button
                    id={"week-toggle-#{item_key(item)}"}
                    type="button"
                    phx-click="toggle-week-ticket"
                    phx-value-key={item_key(item)}
                    aria-expanded={to_string(@disclosures[item_key(item)] == :expanded)}
                    aria-controls={"week-details-#{item_key(item)}"}
                    class="flex w-full cursor-pointer items-center gap-3 p-4 text-left transition-colors hover:bg-sunken focus-visible:outline-2 focus-visible:outline-primary"
                  >
                    <.icon
                      name={
                        if @disclosures[item_key(item)] == :expanded,
                          do: "hero-chevron-down",
                          else: "hero-chevron-right"
                      }
                      class="size-4 shrink-0 text-foreground-softer"
                    />
                    <span class="min-w-0 flex-1 break-words font-medium">{item.title}</span>
                    <span class="shrink-0 font-mono text-xs text-foreground-softer">{item.id}</span>
                  </button>
                  <div class="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 pb-4 text-xs sm:pl-11">
                    <span
                      :if={item.progress_step in ["Done", "Closed, not done"]}
                      id={"week-terminal-#{item_key(item)}"}
                      class="font-medium text-foreground"
                    >
                      {item.progress_step}
                    </span>
                    <ol
                      :if={item.progress_step not in ["Done", "Closed, not done"]}
                      id={"week-progress-#{item_key(item)}"}
                      aria-label="Progress"
                      class="flex flex-wrap items-center gap-1"
                    >
                      <li
                        :for={
                          step <- [
                            "Building",
                            "PR open",
                            if(item.progress_step == "Merged, checking…",
                              do: "Merged, checking…",
                              else: "On staging"
                            ),
                            "In production"
                          ]
                        }
                        aria-current={if item.progress_step == step, do: "step"}
                        class={[
                          "rounded px-2 py-1",
                          if(item.progress_step == step,
                            do:
                              "bg-blue-100 text-blue-900 dark:bg-blue-950 dark:text-blue-200 font-medium",
                            else: "text-foreground-softer"
                          )
                        ]}
                      >
                        {step}
                      </li>
                    </ol>
                    <span
                      :if={item.plain_stage in ["Waiting on you", "Waiting on others", "Discussed"]}
                      id={"week-status-#{item_key(item)}"}
                      class="text-foreground-softer"
                    >
                      {item.plain_stage}
                    </span>
                    <a
                      :for={pr <- item.prs}
                      id={"week-pr-#{item_key(item)}-#{pr["number"]}"}
                      href={pr["url"]}
                      class="underline underline-offset-4 hover:text-foreground-softer"
                    >
                      #{pr["number"]}
                    </a>
                    <time
                      id={"week-day-#{item_key(item)}"}
                      datetime={DateTime.to_iso8601(item.last_activity)}
                      title={
                        Calendar.strftime(
                          DateTime.shift_zone!(item.last_activity, @week.timezone),
                          "%b %-d, %Y at %-I:%M %p %Z"
                        )
                      }
                      class="text-foreground-softer sm:ml-auto"
                    >
                      {item.activity_day}
                    </time>
                  </div>
                  <div
                    :if={@disclosures[item_key(item)] == :expanded}
                    id={"week-details-#{item_key(item)}"}
                    class="border-t border-base bg-sunken px-4 py-4 sm:pl-11"
                  >
                    <p
                      :if={item.missing_staging}
                      id={"week-missing-staging-#{item_key(item)}"}
                      class="mb-3 text-sm text-foreground-softer"
                    >
                      Merged PR head not found in staging
                    </p>
                    <dl class="grid gap-x-8 gap-y-3 text-sm sm:grid-cols-2">
                      <div>
                        <dt class="text-xs text-foreground-softer">Board stage</dt>
                        <dd>{item.stage}</dd>
                      </div>
                      <div>
                        <dt class="text-xs text-foreground-softer">Kind</dt>
                        <dd>{section.label}</dd>
                      </div>
                      <div>
                        <dt class="text-xs text-foreground-softer">Epic</dt>
                        <dd>{if item.epic, do: item.epic.title, else: "None"}</dd>
                      </div>
                      <div>
                        <dt class="text-xs text-foreground-softer">Last activity</dt>
                        <dd>
                          <time
                            datetime={DateTime.to_iso8601(item.last_activity)}
                            title={
                              Calendar.strftime(
                                DateTime.shift_zone!(item.last_activity, @week.timezone),
                                "%b %-d, %Y at %-I:%M %p %Z"
                              )
                            }
                          >
                            {ForemanWeb.RelativeTime.format(item.last_activity)}
                          </time>
                        </dd>
                      </div>
                      <div :if={item.request_ids != []}>
                        <dt class="text-xs text-foreground-softer">Request</dt>
                        <dd class="break-all">{Enum.join(item.request_ids, ", ")}</dd>
                      </div>
                    </dl>
                    <.link
                      id={"week-file-#{item_key(item)}"}
                      navigate={Foreman.Markdown.viewer_path(item.repo, "tickets/#{item.id}.md")}
                      class="mt-4 inline-flex items-center gap-1 text-sm underline underline-offset-4 hover:text-foreground-softer"
                    >
                      <.icon name="hero-document-text" class="size-4" /> Ticket file
                    </.link>
                  </div>
                </article>
              </div>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
