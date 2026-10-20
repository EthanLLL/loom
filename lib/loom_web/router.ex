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
    patch "/agents/:id/files/:name", AgentFileController, :update
    delete "/agents/:id/files/:name", AgentFileController, :delete
    get "/agents/:id/output/*path", AgentOutputController, :show
    patch "/agents/:id/output/*path", AgentOutputController, :update
    delete "/agents/:id/output/*path", AgentOutputController, :delete
    get "/agents/:id/zip/*path", AgentOutputController, :zip
    get "/agents/:id/tree", AgentOutputController, :tree
    post "/agents/:id/canvas", CanvasController, :token

    get "/layout", LayoutController, :show
    put "/layout", LayoutController, :update

    get "/devices", DevicesController, :index
    post "/devices", DevicesController, :create
    patch "/devices/:id", DevicesController, :update
    delete "/devices/:id", DevicesController, :delete
    post "/devices/:id/install", DevicesController, :install

    get "/push", PushController, :show
    post "/push/subscriptions", PushController, :create
    delete "/push/subscriptions", PushController, :delete
  end

  # The `loom-node` CLI on this host, relaying to a device. Not the browser's
  # token: a key only this user can read, and never anything that came through
  # Cloudflare. See `LoomWeb.Plugs.NodeCliAuth`.
  pipeline :node_cli do
    plug LoomWeb.Plugs.NodeCliAuth
  end

  scope "/api/node", LoomWeb do
    pipe_through :node_cli

    get "/list", NodeController, :list
    post "/exec", NodeController, :exec
    get "/read", NodeController, :read
    post "/write", NodeController, :write
  end

  # A device joining: the install script (its one-time code is the credential)
  # and the binary it downloads. See `LoomWeb.NodeInstallController`.
  scope "/node", LoomWeb do
    get "/install/:code", NodeInstallController, :script
    get "/download/:target", NodeInstallController, :download
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

  # The same signed token, for what the user attached rather than what the
  # agent wrote: a separate prefix, since any name could be a directory in
  # `output/`.
  scope "/canvas-files", LoomWeb do
    get "/:id/:token/:name", CanvasController, :attachment
  end

  scope "/", LoomWeb do
    pipe_through :browser

    get "/", SpaController, :index
  end
end
