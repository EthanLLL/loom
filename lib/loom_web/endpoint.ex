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

  # TLS terminates at CloudFront; the WS arrives proxied through nginx, so its
  # Origin won't match our host. Auth is enforced by the token in connect/2.
  socket "/socket", LoomWeb.UserSocket,
    websocket: [check_origin: false],
    longpoll: false

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
