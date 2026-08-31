defmodule GmBmdWeb.Router do
  use GmBmdWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GmBmdWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug GmBmdWeb.FrameHeaders
    plug GmBmdWeb.Identity
  end

  pipeline :health do
    plug :accepts, ["json", "html"]
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", GmBmdWeb do
    pipe_through :health

    get "/healthz", HealthController, :index
  end

  scope "/api", GmBmdWeb do
    pipe_through :api

    get "/ingest/status", IngestController, :status
    post "/ingest", IngestController, :create
  end

  scope "/", GmBmdWeb do
    pipe_through :browser

    live "/", DashboardLive
    live "/daily", DailyLive
    live "/outturn", OutturnLive
    live "/revenue", RevenueLive
    live "/targets", TargetsLive
  end
end
