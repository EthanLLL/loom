defmodule Loom.Push.WebPush do
  @moduledoc """
  The Web Push protocol, sender side: VAPID (RFC 8292) to say who is sending,
  and `aes128gcm` (RFC 8188, RFC 8291) to encrypt the message for the one
  browser it is for. Everything is in `:crypto`, so there is no dependency and
  no account with anyone: the browser's push service (Apple, Google, Mozilla)
  takes a message from whoever holds the key it was subscribed with.
  """

  # One record holds the whole message: push services cap a message at 4 KB.
  @record_size 4096
  @jwt_ttl 12 * 3600

  @doc "A new VAPID key pair, raw: a 65-byte uncompressed P-256 point and its 32-byte secret."
  def generate_keys do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)
    %{public: public, private: private}
  end

  @doc """
  Encrypt `plaintext` for the browser that gave us `ua_public` (its `p256dh`)
  and `auth_secret` (its `auth`), as an `aes128gcm` body. `:keys` and `:salt`
  are fresh per message unless given, which only a test should do.
  """
  def encrypt(plaintext, ua_public, auth_secret, opts \\ []) do
    {as_public, as_private} =
      Keyword.get_lazy(opts, :keys, fn -> :crypto.generate_key(:ecdh, :prime256v1) end)

    salt = Keyword.get_lazy(opts, :salt, fn -> :crypto.strong_rand_bytes(16) end)

    shared = :crypto.compute_key(:ecdh, ua_public, as_private, :prime256v1)
    ikm = hkdf(auth_secret, shared, "WebPush: info" <> <<0>> <> ua_public <> as_public, 32)
    cek = hkdf(salt, ikm, "Content-Encoding: aes128gcm" <> <<0>>, 16)
    nonce = hkdf(salt, ikm, "Content-Encoding: nonce" <> <<0>>, 12)

    # 0x02 marks the last (and only) record.
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, plaintext <> <<2>>, <<>>, true)

    <<salt::binary, @record_size::32, byte_size(as_public)::8, as_public::binary,
      ciphertext::binary, tag::binary>>
  end

  @doc """
  The `Authorization` header for `endpoint`: a JWT for the push service's
  origin, signed with the VAPID key, plus the public key it checks it against.
  `subject` is how the service could reach the sender; Apple insists on one.
  """
  def authorization(endpoint, %{public: public, private: private}, subject, now \\ nil) do
    now = now || System.system_time(:second)
    header = b64(Jason.encode!(%{typ: "JWT", alg: "ES256"}))
    claims = b64(Jason.encode!(%{aud: origin(endpoint), exp: now + @jwt_ttl, sub: subject}))
    input = header <> "." <> claims

    # `:crypto` signs in DER; a JWT wants r and s side by side.
    der = :crypto.sign(:ecdsa, :sha256, input, [private, :prime256v1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)

    "vapid t=#{input}.#{b64(<<r::256, s::256>>)}, k=#{b64(public)}"
  end

  @doc """
  Send `payload` to one subscription (`endpoint`, `p256dh`, `auth`, the last
  two base64url as the browser gave them). `{:ok, status, body}` with the push
  service's status — 201 delivered, 404 or 410 the subscription is gone — and
  its body, which says why when it refuses; `{:error, reason}` if it could not
  be reached.
  """
  def deliver(subscription, payload, keys, subject) do
    body = encrypt(payload, decode!(subscription.p256dh), decode!(subscription.auth))

    headers = [
      {~c"authorization",
       String.to_charlist(authorization(subscription.endpoint, keys, subject))},
      {~c"content-encoding", ~c"aes128gcm"},
      # A day: a phone that is off longer than that does not need to hear
      # about a turn from yesterday.
      {~c"ttl", ~c"86400"},
      {~c"urgency", ~c"high"}
    ]

    request =
      {String.to_charlist(subscription.endpoint), headers, ~c"application/octet-stream", body}

    http = [timeout: 15_000, connect_timeout: 10_000, ssl: ssl_options()]

    case :httpc.request(:post, request, http, body_format: :binary) do
      {:ok, {{_, status, _}, _headers, body}} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  end

  def b64(bin), do: Base.url_encode64(bin, padding: false)

  def decode!(text), do: Base.url_decode64!(String.trim_trailing(text, "="), padding: false)

  # HKDF (RFC 5869) for one block, which is all either key needs.
  defp hkdf(salt, ikm, info, length) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    binary_part(:crypto.mac(:hmac, :sha256, prk, info <> <<1>>), 0, length)
  end

  defp origin(endpoint) do
    uri = URI.parse(endpoint)
    default = URI.default_port(uri.scheme)
    port = if uri.port && uri.port != default, do: ":#{uri.port}", else: ""
    "#{uri.scheme}://#{uri.host}#{port}"
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end
end
