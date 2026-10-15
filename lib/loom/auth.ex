defmodule Loom.Auth do
  @moduledoc """
  Minimal single-password auth. The password is configured via `LOOM_PASSWORD`.
  On success we mint a signed token (no DB, no expiry logic beyond the signing
  max_age); the client keeps it in localStorage, so a device stays logged in
  until the token expires — closing an iOS home-screen app is how it reloads,
  and a password prompt on every reload was the alternative.
  """

  @salt "loom auth token"
  # The only expiry there is: the client keeps the token until this runs out
  # (or a 401 clears it).
  @max_age 60 * 60 * 24 * 30

  @doc "Verify a plaintext password against the configured one (constant-time)."
  def valid_password?(password) when is_binary(password) do
    configured = Application.get_env(:loom, :password, "")
    Plug.Crypto.secure_compare(password, configured)
  end

  def valid_password?(_), do: false

  @doc "Mint a signed token for an authenticated client."
  def mint_token do
    Phoenix.Token.sign(LoomWeb.Endpoint, @salt, %{ok: true})
  end

  @doc "Verify a token minted by `mint_token/0`."
  def verify_token(token) when is_binary(token) do
    case Phoenix.Token.verify(LoomWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_token(_), do: {:error, :missing}
end
