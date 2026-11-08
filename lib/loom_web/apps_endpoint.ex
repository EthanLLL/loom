defmodule LoomWeb.AppsEndpoint do
  @moduledoc """
  The apps on an origin of their own — `LOOM_APPS_URL`, say
  `https://loom-apps.luozhen.cloud`, tunnelled to `LOOM_APPS_PORT` (5000) —
  serving `/apps/…` and nothing of loom's, so no host or path here can reach
  loom's routes.

  Off loom's origin a page cannot read loom's login, so it needs no sandbox:
  it gets cookies, storage and PWA install like any site, and a private app is
  opened by a cookie its signed link sets (`LoomWeb.Apps`). The apps of one
  loom share this origin, so they can read each other's storage.

  An endpoint rather than a bare Bandit so Phoenix channels can be offered to
  apps here later.
  """
  use Phoenix.Endpoint, otp_app: :loom

  # The libraries loom offers pages it serves (`LoomWeb.Endpoint`), at the same
  # path: an app or a copied deck that links `/vendor/reveal.js/…` works here too.
  plug Plug.Static,
    at: "/vendor",
    from: {:loom, "priv/static/vendor"},
    gzip: false,
    cache_control_for_etags: "public, max-age=86400"

  plug Plug.RequestId
  plug LoomWeb.Apps
  plug :not_found

  def not_found(conn, _opts) do
    conn |> Plug.Conn.send_resp(404, "not found") |> Plug.Conn.halt()
  end
end
