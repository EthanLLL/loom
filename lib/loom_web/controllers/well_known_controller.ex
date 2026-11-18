defmodule LoomWeb.WellKnownController do
  @moduledoc """
  `GET /.well-known/apple-app-site-association`: the iOS apps (`:ios_apps`,
  `LOOM_IOS_APP_ID`) that may use this Loom's passkeys and saved password —
  the `webcredentials` an app's Associated Domains entitlement asks Apple
  about. Apple's CDN fetches it, unauthenticated; it must be JSON, served
  without a redirect. 404 when no app is configured.
  """
  use LoomWeb, :controller

  def apple_app_site_association(conn, _params) do
    case Application.get_env(:loom, :ios_apps, []) do
      [] -> send_resp(conn, 404, "")
      apps -> json(conn, %{webcredentials: %{apps: apps}})
    end
  end
end
