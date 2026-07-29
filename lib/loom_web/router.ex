defmodule LoomWeb.Router do
  use LoomWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authed_api do
    plug :accepts, ["json"]
    plug LoomWeb.Plugs.RequireAuth
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
