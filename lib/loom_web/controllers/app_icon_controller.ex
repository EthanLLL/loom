defmodule LoomWeb.AppIconController do
  @moduledoc """
  `GET /app-icons/:name/:file`: an app's icon in the Apps grid, from the
  registry's own copy (`Loom.Apps`), so drawing the grid wakes no app.

  Unauthenticated, as the shell's own assets are: an `<img>` sends no bearer
  token, and an icon is no secret. Only an app's current icon is served. The
  name changes with its bytes, so it is cached for good. An SVG is a document
  that could run script at Loom's origin if opened by itself; the policy
  below keeps it a picture.
  """
  use LoomWeb, :controller

  def show(conn, %{"name" => name, "file" => file}) do
    case Loom.Apps.icon(name, file) do
      {:ok, path} ->
        if File.regular?(path) do
          conn
          |> put_resp_content_type(MIME.from_path(path), nil)
          |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
          |> put_resp_header(
            "content-security-policy",
            "default-src 'none'; style-src 'unsafe-inline'; sandbox"
          )
          |> put_resp_header("x-content-type-options", "nosniff")
          |> send_file(200, path)
        else
          send_resp(conn, 404, "")
        end

      :error ->
        send_resp(conn, 404, "")
    end
  end
end
