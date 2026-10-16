defmodule LoomWeb.Router do
  use LoomWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
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

    get "/agents", AgentSessionController, :index
    post "/agents", AgentSessionController, :create
    patch "/agents/:id", AgentSessionController, :update
    delete "/agents/:id", AgentSessionController, :delete

    post "/agents/:id/files", AgentFileController, :create
    get "/agents/:id/files/:name", AgentFileController, :show
    get "/agents/:id/output/*path", AgentOutputController, :show
    get "/agents/:id/zip/*path", AgentOutputController, :zip
    post "/agents/:id/canvas", CanvasController, :token

    get "/layout", LayoutController, :show
    put "/layout", LayoutController, :update
  end

  # The UI itself. Last so it can never shadow an API route, and only `/` —
  # see `LoomWeb.SpaController`. Unauthenticated on purpose: the app shell is
  # a login form until the password is entered, and every route that touches a
  # session is behind `RequireAuth` or the socket's token check.
  # No bearer token and no `accepts`: an iframe asks for whatever the page
  # references. The signed path is the credential; see `CanvasController`.
  scope "/canvas", LoomWeb do
    get "/:id/:token", CanvasController, :show
    get "/:id/:token/*path", CanvasController, :show
  end

  scope "/", LoomWeb do
    pipe_through :browser

    get "/", SpaController, :index
  end
end
