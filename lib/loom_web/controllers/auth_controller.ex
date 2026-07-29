defmodule LoomWeb.AuthController do
  use LoomWeb, :controller

  # POST /api/login — exchange the password for a signed token.
  def login(conn, %{"password" => password}) do
    if Loom.Auth.valid_password?(password) do
      json(conn, %{token: Loom.Auth.mint_token()})
    else
      conn |> put_status(:unauthorized) |> json(%{error: "invalid_password"})
    end
  end

  def login(conn, _), do: conn |> put_status(:bad_request) |> json(%{error: "missing_password"})
end
