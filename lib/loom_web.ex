defmodule LoomWeb do
  @moduledoc """
  The entrypoint for defining the web interface: controllers, channels, etc.

  This is a JSON API + WebSocket backend — no HTML templates, no LiveView. The
  UI is a separate Vite app (see `frontend/`) whose build output is served from
  `priv/static` by `Plug.Static`, so one BEAM process serves both and there is
  no web server in front.

      use LoomWeb, :controller
      use LoomWeb, :channel
  """

  # `assets`, `fonts` and `index.html` are the Vite build, copied in by
  # `mix assets.deploy`. Nothing else in `priv/static` is reachable.
  def static_paths, do: ~w(assets fonts icons favicon.ico favicon.svg icons.svg manifest.webmanifest robots.txt index.html)

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
