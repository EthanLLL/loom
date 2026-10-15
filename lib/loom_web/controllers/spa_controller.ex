defmodule LoomWeb.SpaController do
  @moduledoc """
  Serves the frontend's `index.html` at `/`.

  `Plug.Static` serves files, not directory indexes, so without this the root
  URL 404s while every asset beside it loads. Only `/` is routed here: the UI
  has no client-side router, so a catch-all would turn a typo — or a missing
  API route — into a silent 200 of the app shell.
  """
  use LoomWeb, :controller

  def index(conn, _params) do
    path = Path.join(:code.priv_dir(:loom), "static/index.html")

    if File.regular?(path) do
      conn
      |> put_resp_content_type("text/html")
      # The shell is tiny and names fingerprinted assets, so it must never be
      # cached: a stale one points at files the new release no longer has.
      |> put_resp_header("cache-control", "no-cache")
      |> send_file(200, path)
    else
      # Running without a built frontend — `mix phx.server` during development,
      # where Vite serves the UI on its own port and proxies here.
      conn
      |> put_status(:not_found)
      |> json(%{
        error: "no frontend build in priv/static",
        hint: "run `mix assets.deploy`, or use the Vite dev server"
      })
    end
  end
end
