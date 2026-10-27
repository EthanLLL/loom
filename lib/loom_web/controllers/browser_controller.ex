defmodule LoomWeb.BrowserController do
  @moduledoc """
  Upgrades to `LoomWeb.VncSocket`. A browser can't set headers on a WebSocket,
  so the login token comes as `?token=`, as it does for `/socket`.
  """
  use LoomWeb, :controller

  def vnc(conn, params) do
    case Loom.Auth.verify_token(params["token"]) do
      :ok ->
        # A screen that doesn't change sends nothing, and noVNC doesn't ping, so
        # the idle limit is long; a dropped connection ends it either way.
        conn
        |> WebSockAdapter.upgrade(LoomWeb.VncSocket, nil,
          timeout: :timer.hours(4),
          compress: true
        )
        |> halt()

      {:error, _} ->
        send_resp(conn, 401, "")
    end
  end
end
