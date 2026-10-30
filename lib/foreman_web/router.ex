defmodule ForemanWeb.Router do
  use ForemanWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ForemanWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug ForemanWeb.AgentAuth
    plug :accepts, ["json"]
  end

  scope "/", ForemanWeb do
    pipe_through :browser

    get "/request-images/:id/:index", ReviewImageController, :show

    live_session :foreman, on_mount: ForemanWeb.RequestCount do
      live "/needs-you", NeedsYouLive, :index
      live "/answers", AnswersLive, :index
      live "/", InitiativesLive, :index
      live "/settings", SettingsLive, :index
      live "/previews", PreviewsLive, :index
      live "/week", WeekLive, :index
      live "/documents/:repo", DocumentsLive, :show
      live "/pull-requests", PullRequestsLive, :index
      live "/epics/:repo/:id", EpicLive, :show
    end
  end

  scope "/api", ForemanWeb do
    pipe_through :api
    get "/tickets/:repo/:id", AgentController, :show
    post "/tickets/:repo/:id/events", AgentController, :event
    post "/commands", AgentController, :command
    get "/repos", AgentController, :catalog
    post "/repos/:repo/sync", AgentController, :sync
  end

  # Other scopes may use custom stacks.
  # scope "/api", ForemanWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:foreman, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ForemanWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
