defmodule Loom.Auth.WebAuthn do
  @moduledoc """
  The two WebAuthn ceremonies a passkey needs, checked with `:crypto` alone.

  No CBOR: at registration the browser hands over the public key itself
  (`AuthenticatorAttestationResponse.getPublicKey()`, SubjectPublicKeyInfo DER)
  and the authenticator data (`getAuthenticatorData()`), so the attestation
  object is never parsed. Attestation is not verified anyway — the browser is
  asked for `none`, and registering needs a signed-in device already.

  What is checked, both times: the client data's `type`, its `challenge`
  (the caller matches it to one it issued), its origin (https, or http on
  localhost), the authenticator data's RP id hash, and the user-present and
  user-verified flags — the latter is the fingerprint or face. A sign-in also
  checks the signature over `authenticatorData ‖ SHA-256(clientDataJSON)`.

  The RP id is the origin's host, recorded with the passkey when it is made:
  the browser only lets that site use it, so there is no Host header to trust.
  """

  import Bitwise

  @user_present 0x01
  @user_verified 0x04

  @doc """
  Check a registration. `{:ok, %{rp_id:, public_key:, challenge:}}`, the key
  as base64 DER to store, or `{:error, reason}`.
  """
  def register(%{"client_data" => cd, "authenticator_data" => ad, "public_key" => pk}) do
    with {:ok, client_json} <- b64(cd),
         {:ok, client} <- client(client_json, "webauthn.create"),
         {:ok, rp_id} <- rp_id(client["origin"]),
         {:ok, auth_data} <- b64(ad),
         :ok <- auth_data(auth_data, rp_id),
         {:ok, der} <- b64(pk),
         {:ok, _key} <- public_key(der) do
      {:ok, %{rp_id: rp_id, public_key: Base.encode64(der), challenge: client["challenge"]}}
    end
  end

  def register(_), do: {:error, :malformed}

  @doc """
  Check a sign-in against a stored passkey (`%{rp_id:, public_key:}`).
  `{:ok, challenge}` for the caller to match, or `{:error, reason}`.
  """
  def verify(
        %{"client_data" => cd, "authenticator_data" => ad, "signature" => sig},
        %{rp_id: rp_id, public_key: pk}
      ) do
    with {:ok, client_json} <- b64(cd),
         {:ok, client} <- client(client_json, "webauthn.get"),
         {:ok, ^rp_id} <- rp_id(client["origin"]),
         {:ok, auth_data} <- b64(ad),
         :ok <- auth_data(auth_data, rp_id),
         {:ok, signature} <- b64(sig),
         {:ok, key} <- public_key(Base.decode64!(pk)),
         true <- signed?(auth_data <> :crypto.hash(:sha256, client_json), signature, key) do
      {:ok, client["challenge"]}
    else
      {:ok, _other_rp} -> {:error, :origin}
      false -> {:error, :signature}
      {:error, _} = error -> error
    end
  end

  def verify(_, _), do: {:error, :malformed}

  defp client(json, type) do
    case Jason.decode(json) do
      {:ok, %{"type" => ^type, "challenge" => c, "origin" => o} = client}
      when is_binary(c) and is_binary(o) ->
        {:ok, client}

      _ ->
        {:error, :client_data}
    end
  end

  defp rp_id(origin) do
    case URI.parse(origin) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> {:ok, host}
      %URI{scheme: "http", host: "localhost"} -> {:ok, "localhost"}
      _ -> {:error, :origin}
    end
  end

  defp auth_data(<<hash::binary-32, flags, _count::32, _rest::binary>>, rp_id) do
    cond do
      hash != :crypto.hash(:sha256, rp_id) -> {:error, :rp_id}
      (flags &&& @user_present) == 0 -> {:error, :not_present}
      (flags &&& @user_verified) == 0 -> {:error, :not_verified}
      true -> :ok
    end
  end

  defp auth_data(_, _), do: {:error, :authenticator_data}

  # P-256 (alg -7) or RSA (alg -257, which Windows Hello may choose).
  defp public_key(der) do
    case :public_key.pem_entry_decode({:SubjectPublicKeyInfo, der, :not_encrypted}) do
      {{:ECPoint, _}, {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}}} = key -> {:ok, key}
      {:RSAPublicKey, _, _} = key -> {:ok, key}
      _ -> {:error, :key_type}
    end
  rescue
    _ -> {:error, :public_key}
  end

  defp signed?(message, signature, key) do
    :public_key.verify(message, :sha256, signature, key)
  rescue
    _ -> false
  end

  defp b64(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :encoding}
    end
  end

  defp b64(_), do: {:error, :encoding}
end
