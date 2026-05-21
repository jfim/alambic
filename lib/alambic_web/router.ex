defmodule AlambicWeb.Router do
  use AlambicWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AlambicWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AlambicWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/api", AlambicWeb do
    pipe_through :api

    post "/extract", ExtractController, :create
    post "/clean", CleanController, :create

    get "/models", Admin.ModelController, :index
    post "/models/:version/activate", Admin.ModelController, :activate
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:alambic, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AlambicWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
