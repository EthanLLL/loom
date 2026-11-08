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
  # Compressed: opening a session replays its transcript, which is JSON and
  # several hundred KB for a long one, and shrinks to about a third.
  socket "/socket", LoomWeb.UserSocket,
    websocket: [check_origin: false, compress: true],
    longpoll: false

  # `loom-node daemon` on the user's own machines. Its own socket, so a device
  # token can never open a session or a terminal; see `LoomWeb.NodeSocket`.
  # Shorter than the default timeout so a device that vanished without closing
  # (a laptop lid, a dropped Wi-Fi) is let go within a minute; the daemon
  # heartbeats every 15s.
  socket "/node", LoomWeb.NodeSocket,
    websocket: [check_origin: false, timeout: 45_000],
    longpoll: false

  # The frontend, straight from the release. There is no web server in front,
  # so if this is not here nothing serves the UI at all and the browser gets
  # only `/api`.
  #
  # Vite fingerprints every filename under `assets/`, so those are cached for
  # good: a new release names new files, and `index.html` — never cached, see
  # `LoomWeb.SpaController` — is what points at them.
  plug Plug.Static,
    at: "/assets",
    from: {:loom, "priv/static/assets"},
    gzip: false,
    cache_control_for_etags: "public, max-age=31536000, immutable"

  # Libraries for pages the agent writes (reveal.js, KaTeX; see
  # `frontend/tools/vendor.mjs`), so a deck opens whenever loom does, CDN or
  # not. A canvas page runs on an opaque origin, which makes every request it
  # sends here cross-origin, and fonts load only with CORS — hence the header.
  # Unversioned paths, so a day rather than for good.
  plug Plug.Static,
    at: "/vendor",
    from: {:loom, "priv/static/vendor"},
    gzip: false,
    cache_control_for_etags: "public, max-age=86400",
    headers: %{"access-control-allow-origin" => "*"}

  # Fonts and icons: unversioned too, and they change about never. The terminal
  # fonts are 2.8 MB each, which is what makes this worth having.
  plug Plug.Static,
    at: "/",
    from: :loom,
    gzip: false,
    cache_control_for_etags: "public, max-age=86400",
    only: ~w(fonts icons favicon.ico favicon.svg icons.svg manifest.webmanifest robots.txt)

  # Asked about every time: the shell, and the service worker, whose update
  # check should reach the server rather than a cached copy.
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
