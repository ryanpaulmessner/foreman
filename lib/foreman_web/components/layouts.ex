defmodule ForemanWeb.Layouts do
  use ForemanWeb, :html
  embed_templates "layouts/*"
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :active, :atom, default: :initiatives
  attr :repos, :list, default: []
  attr :filters, :map, default: %{}
  attr :pending_count, :integer, default: 0
  attr :drawer_state, :atom, default: :closed
  attr :drawer_error, :string, default: nil
  attr :streams, :map, default: %{}
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-base text-sm text-foreground md:flex">
      <aside class="flex shrink-0 flex-col gap-6 border-b border-base bg-sunken px-3 py-4 md:sticky md:top-0 md:h-screen md:overflow-y-auto md:w-60 md:border-r md:border-b-0">
        <a href="/" class="flex items-center gap-2.5 px-2.5 py-1 text-[15px] font-semibold">
          <.icon name="hero-ellipsis-horizontal-circle" class="size-6" /> foreman
        </a>
        <nav aria-label="Main" class="space-y-1">
          <div class="grid">
            <.link
              id="needs-you-link"
              navigate={~p"/needs-you"}
              class={["bb-nav [grid-area:1/1] pr-14", @active == :needs_you && "bb-nav-active"]}
              aria-current={@active == :needs_you && "page"}
            >
              <.icon name="hero-inbox" class="size-4" /> Needs you
            </.link>
            <button
              id="needs-you-badge"
              type="button"
              phx-click="open-request-drawer"
              aria-label={"Needs you: #{@pending_count} pending requests"}
              aria-haspopup="dialog"
              aria-controls="request-drawer"
              aria-expanded={to_string(@drawer_state == :open)}
              class="[grid-area:1/1] self-center justify-self-end mr-2.5 cursor-pointer rounded-full leading-none border border-base bg-base px-2 py-0.5 text-xs font-semibold text-foreground focus-visible:outline-2 focus-visible:outline-primary"
            >
              <span :if={@pending_count > 0} id="needs-you-count">{@pending_count}</span>
              <span :if={@pending_count == 0}>0</span>
            </button>
          </div>
          <.link
            navigate={~p"/"}
            class={["bb-nav", @active in [:initiatives, :epic] && "bb-nav-active"]}
            aria-current={@active in [:initiatives, :epic] && "page"}
          >
            <.icon name="hero-bars-3-bottom-left" class="size-4" /> Initiatives
          </.link>
          <.link
            id="this-week-link"
            navigate={~p"/week"}
            class={["bb-nav", @active == :week && "bb-nav-active"]}
            aria-current={@active == :week && "page"}
          >
            <.icon name="hero-calendar-days" class="size-4" /> This week
          </.link>
          <.link
            navigate={~p"/pull-requests"}
            class={["bb-nav", @active == :pull_requests && "bb-nav-active"]}
            aria-current={@active == :pull_requests && "page"}
          >
            <.icon name="hero-code-bracket" class="size-4" /> Pull requests
          </.link>
          <.link
            navigate={~p"/previews"}
            class={["bb-nav", @active == :previews && "bb-nav-active"]}
            aria-current={@active == :previews && "page"}
          >
            <.icon name="hero-eye" class="size-4" /> Previews
          </.link>
          <.link
            navigate={~p"/settings"}
            class={["bb-nav", @active == :settings && "bb-nav-active"]}
            aria-current={@active == :settings && "page"}
          >
            <.icon name="hero-cog-6-tooth" class="size-4" /> Settings
          </.link>
          <div
            id="browser-notifications"
            hidden
            phx-hook="BrowserNotifications"
            phx-update="ignore"
            data-machine={Jason.encode!(Foreman.NotificationPermission.browser_table())}
          >
            <button
              id="enable-notifications"
              type="button"
              hidden
              class="bb-nav w-full cursor-pointer text-left"
            >
              <.icon name="hero-bell" class="size-4" /> Turn on notifications
            </button>
          </div>
        </nav>
        <section :if={@repos != []} class="space-y-2 px-2.5" aria-label="Projects">
          <h2 class="bb-label">Projects · tickets</h2>
          <div :for={repo <- @repos} class="bb-project-row flex items-center gap-1">
            <.link
              id={"sidebar-project-" <> repo["key"]}
              patch={if @active == :initiatives, do: project_path(@filters, repo["key"])}
              navigate={if @active != :initiatives, do: project_path(%{}, repo["key"])}
              class={[
                "bb-project bb-nav min-w-0 flex-1 text-xs",
                @active == :initiatives && @filters["project"] == repo["key"] && "bb-nav-active"
              ]}
              aria-current={@active == :initiatives && @filters["project"] == repo["key"] && "true"}
            >
              <span class="bb-project-dot"></span>
              <span class="min-w-0 flex-1 truncate" title={repo["key"]}>{repo["key"]}</span>
              <span class="text-foreground-softer">
                {if repo["health"].state == "unreachable", do: "down", else: repo["count"]}
              </span>
            </.link>
            <.link
              id={"sidebar-documents-" <> repo["key"]}
              navigate={~p"/documents/#{repo["key"]}"}
              class="rounded p-2 text-foreground-softer hover:bg-base hover:text-foreground"
              aria-label={"Documents · " <> repo["key"]}
              title="Documents"
            >
              <.icon name="hero-document-text" class="size-4" />
            </.link>
          </div>
        </section>
        <div class="mt-auto space-y-4 px-2.5">
          <div class="flex gap-2">
            <button
              id="theme-light"
              class="bb-theme"
              aria-label="Light theme"
              phx-click={JS.dispatch("phx:set-theme")}
              data-phx-theme="light"
            >
              <.icon name="hero-sun" class="size-4" />
            </button>
            <button
              id="theme-dark"
              class="bb-theme"
              aria-label="Dark theme"
              phx-click={JS.dispatch("phx:set-theme")}
              data-phx-theme="dark"
            >
              <.icon name="hero-moon" class="size-4" />
            </button>
          </div>
        </div>
      </aside>
      <main class="min-w-0 flex-1 space-y-5 px-5 pt-6 pb-10 lg:px-7">
        {render_slot(@inner_block)}
      </main>
    </div>
    <ForemanWeb.RequestDrawer.drawer
      :if={Map.has_key?(@streams, :drawer_requests)}
      state={@drawer_state}
      error={@drawer_error}
      streams={@streams}
    />
    <.flash_group flash={@flash} />
    """
  end

  defp project_path(filters, project) do
    filters
    |> Foreman.Initiatives.Filters.toggle_project(project)
    |> Foreman.Initiatives.Filters.path()
  end

  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div id="flash-group" aria-live="polite" class="fixed right-5 bottom-5 z-50 space-y-2">
      <div
        :for={kind <- [:info, :error]}
        :if={Phoenix.Flash.get(@flash, kind)}
        class="bb-panel"
        phx-click={JS.push("lv:clear-flash", value: %{key: kind})}
      >
        {Phoenix.Flash.get(@flash, kind)}
      </div>
    </div>
    """
  end
end
