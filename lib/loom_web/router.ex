defmodule LoomWeb.Router do
  use LoomWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LoomWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authed_api do
    plug :accepts, ["json"]
    plug LoomWeb.Plugs.RequireAuth
  end

  scope "/", LoomWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/api", LoomWeb do
    pipe_through :api

    post "/login", AuthController, :login
  end

  scope "/api", LoomWeb do
    pipe_through :authed_api

    get "/sessions", SessionController, :index
    post "/sessions", SessionController, :create
    delete "/sessions/:id", SessionController, :delete

    get "/layout", LayoutController, :show
    put "/layout", LayoutController, :update
  end
end
