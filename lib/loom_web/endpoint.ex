defmodule LoomWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :loom

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_loom_key",
    signing_salt: "NwmtGqtY",
    same_site: "Lax"
  ]

  # TLS terminates at the edge (Cloudflare) and the WS arrives proxied, so its
  # Origin won't match our host. Auth is enforced by the token in connect/2.
  socket "/socket", LoomWeb.UserSocket,
    websocket: [check_origin: false],
    longpoll: false

  # The frontend, straight from the release. There is no web server in front,
  # so if this is not here nothing serves the UI at all and the browser gets
  # only `/api`. Vite fingerprints every asset filename, which is what makes
  # the long cache on versioned requests safe.
  plug Plug.Static,
    at: "/",
    from: :loom,
    gzip: false,
    only: LoomWeb.static_paths()

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    # The multipart limit is per request and covers a whole drop of files;
    # `Loom.Agent.Files` enforces the real per-file cap and reports it properly,
    # while exceeding this one is a bare 413 from Plug.
    parsers: [:urlencoded, {:multipart, length: 120_000_000}, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug LoomWeb.Router
end
