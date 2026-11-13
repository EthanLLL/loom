defmodule LoomWeb.AuthController do
  @moduledoc """
  Signing in, and the settings that decide how; see `Loom.Auth`.

  Open to anyone, for the sign-in page:

  - `GET /api/auth/options` — `%{passkey:, totp:}`: whether to offer a passkey,
    and whether the password needs a code.
  - `POST /api/login` with `%{password:, code:}`.
  - `POST /api/auth/passkey/challenge`, then `POST /api/auth/passkey/login`
    with the assertion's `id`, `client_data`, `authenticator_data` and
    `signature`, base64url.

  Signed in:

  - `GET /api/auth` — passkeys, authenticator, logins, which one is this
    device; and a `token` to keep when the device's own is from before logins.
  - `POST /api/auth/passkeys/challenge`, then `POST /api/auth/passkeys` with
    `id`, `client_data`, `authenticator_data`, `public_key`; `DELETE` one.
  - `POST /api/auth/totp` for a secret, `POST /api/auth/totp/confirm` with a
    code from the app for the recovery codes; `DELETE /api/auth/totp`.
  - `DELETE /api/auth/logins/:id` signs that device out, socket included.
  """
  use LoomWeb, :controller

  alias Loom.Auth

  def options(conn, _params), do: json(conn, Auth.options())

  def login(conn, %{"password" => password} = params) do
    case Auth.password_login(password, params["code"], client(conn)) do
      {:ok, token} -> json(conn, %{token: token})
      {:error, :locked} -> conn |> put_status(429) |> json(%{error: "locked"})
      {:error, _} -> conn |> put_status(:unauthorized) |> json(%{error: "invalid_password"})
    end
  end

  def login(conn, _), do: conn |> put_status(:bad_request) |> json(%{error: "missing_password"})

  def login_challenge(conn, _params), do: json(conn, %{challenge: Auth.challenge(:login)})

  def passkey_login(conn, params) do
    case Auth.passkey_login(params, client(conn)) do
      {:ok, token} -> json(conn, %{token: token})
      {:error, reason} -> conn |> put_status(:unauthorized) |> json(%{error: to_string(reason)})
    end
  end

  def show(conn, _params) do
    upgrade =
      case conn.assigns.login do
        :legacy ->
          {:ok, token} = Auth.upgrade(client(conn))
          %{token: token}

        _ ->
          %{}
      end

    json(conn, Auth.overview() |> Map.put(:current, conn.assigns.login) |> Map.merge(upgrade))
  end

  def register_challenge(conn, _params) do
    exclude = Enum.map(Auth.overview().passkeys, & &1.id)
    json(conn, %{challenge: Auth.challenge(:register), exclude: exclude})
  end

  def register(conn, params) do
    case Auth.register_passkey(params, client(conn)) do
      {:ok, passkey} -> json(conn, %{passkey: passkey})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: to_string(reason)})
    end
  end

  def delete_passkey(conn, %{"id" => id}) do
    :ok = Auth.delete_passkey(id)
    send_resp(conn, 204, "")
  end

  def totp_begin(conn, _params), do: json(conn, %{secret: Auth.totp_begin()})

  def totp_confirm(conn, params) do
    case Auth.totp_confirm(params["code"]) do
      {:ok, codes} ->
        # Tokens from before logins stop working now; drop their sockets too.
        LoomWeb.Endpoint.broadcast("login:legacy", "disconnect", %{})
        json(conn, %{recovery_codes: codes})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: to_string(reason)})
    end
  end

  def totp_remove(conn, _params) do
    :ok = Auth.totp_remove()
    send_resp(conn, 204, "")
  end

  def revoke(conn, %{"id" => id}) do
    :ok = Auth.revoke(id)
    LoomWeb.Endpoint.broadcast("login:#{id}", "disconnect", %{})
    send_resp(conn, 204, "")
  end

  # What a login records about the device: a name from its user agent, and
  # the address Cloudflare saw it at.
  defp client(conn) do
    ua = conn |> get_req_header("user-agent") |> List.first() || ""

    ip =
      case get_req_header(conn, "cf-connecting-ip") do
        [ip | _] -> ip
        [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
      end

    %{name: device_name(ua), ip: ip}
  end

  @doc false
  def device_name(ua) do
    platform =
      cond do
        ua =~ "iPhone" -> "iPhone"
        ua =~ "iPad" -> "iPad"
        ua =~ "Android" -> "Android"
        ua =~ "Windows" -> "Windows"
        ua =~ "Macintosh" -> "Mac"
        ua =~ "CrOS" -> "ChromeOS"
        ua =~ "Linux" -> "Linux"
        true -> "Unknown device"
      end

    browser =
      cond do
        ua =~ "Edg" -> "Edge"
        ua =~ "Firefox" or ua =~ "FxiOS" -> "Firefox"
        ua =~ "CriOS" or ua =~ "Chrome" -> "Chrome"
        ua =~ "Safari" -> "Safari"
        true -> nil
      end

    if browser, do: "#{platform} · #{browser}", else: platform
  end
end
