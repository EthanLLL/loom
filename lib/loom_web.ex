defmodule LoomWeb do
  @moduledoc """
  The entrypoint for defining the web interface: controllers, channels, etc.

  This is a JSON API + WebSocket backend only — no HTML/LiveView. The UI is a
  separate frontend app (see `frontend/`).

      use LoomWeb, :controller
      use LoomWeb, :channel
  """

  def static_paths, do: ~w(favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: LoomWeb.Endpoint,
        router: LoomWeb.Router,
        statics: LoomWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/channel/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
