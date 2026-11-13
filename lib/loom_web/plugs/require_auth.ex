defmodule LoomWeb.Plugs.RequireAuth do
  @moduledoc """
  Rejects API requests lacking a valid bearer token, and puts the login it
  names (`Loom.Auth`) in `conn.assigns.login`.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, login} <- Loom.Auth.verify_token(token) do
      assign(conn, :login, login)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, ~s({"error":"unauthorized"}))
        |> halt()
    end
  end
end
