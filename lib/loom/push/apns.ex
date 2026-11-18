defmodule Loom.Push.APNs do
  @moduledoc """
  Apple's push service, for an iPhone app of one's own, sender side: an
  HTTP/2 POST to the device's endpoint, `https://api.push.apple.com/3/device/<token>`
  (`api.sandbox.push.apple.com` for a development build), signed with a token
  from the team's APNs key (a `.p8` from the developer account, one for all of
  the team's apps).

  - **Configured or not at all.** `:key_file`, `:key_id` and `:team_id` under
    `config :loom, Loom.Push.APNs`; without them devices cannot sign up for it,
    and Web Push is unaffected.
  - **One token for 50 minutes.** Apple refuses a token older than an hour and
    one renewed more than every 20 minutes (`TooManyProviderTokenUpdates`).
  - **A connection per message**, closed after it: a few a day per device, not
    worth holding one open.

  A device's `endpoint` is where its notifications are posted, as a Web Push
  one is; `topic` is the app's bundle id, which the key's team must own.
  """

  @token_ttl 50 * 60

  @doc "Whether this Loom has an APNs key to send with."
  def configured?, do: match?(%{key_file: _, key_id: _, team_id: _}, config())

  @doc """
  The endpoint for a device's token (hex, as the app has it) in its
  environment, or `:error` for what is not one.
  """
  def endpoint(token, sandbox) when is_binary(token) and is_boolean(sandbox) do
    if token =~ ~r/\A[0-9a-fA-F]{32,200}\z/,
      do:
        {:ok,
         "https://#{if sandbox, do: "api.sandbox.", else: "api."}push.apple.com/3/device/#{String.downcase(token)}"},
      else: :error
  end

  def endpoint(_token, _sandbox), do: :error

  @doc """
  The payload for a notification: shown by iOS itself, one thread per session,
  with the session for the app to open when it is tapped.
  """
  def payload(title, body, session_id) do
    Jason.encode!(%{
      aps: %{
        alert: %{title: title, body: body},
        sound: "default",
        "thread-id": session_id || "loom"
      },
      session: session_id
    })
  end

  @doc """
  Send `payload` to one device (`endpoint`, `topic`). `{:ok, status, body}`
  with Apple's status — 200 delivered, 410 the app is gone from the device, 400
  `BadDeviceToken` a token from the other environment — and its body, which
  says why when it refuses; `{:error, reason}` if Apple could not be reached.
  """
  def deliver(%{endpoint: endpoint, topic: topic}, payload) do
    %URI{host: host, path: path} = URI.parse(endpoint)
    session = Jason.decode!(payload)["session"]

    headers =
      [
        {"authorization", "bearer " <> token()},
        {"apns-topic", topic},
        {"apns-push-type", "alert"},
        # A day, as for Web Push.
        {"apns-expiration", Integer.to_string(System.system_time(:second) + 86_400)},
        # One notification per session: a newer turn replaces the older one.
        {"apns-collapse-id", session || "loom"}
      ]

    with {:ok, conn} <-
           Mint.HTTP.connect(:https, host, 443,
             mode: :passive,
             protocols: [:http2],
             transport_opts: [timeout: 10_000]
           ) do
      result =
        with {:ok, conn, ref} <- Mint.HTTP.request(conn, "POST", path, headers, payload) do
          receive_response(conn, ref, %{status: nil, body: ""})
        end

      case result do
        {:ok, conn, status, body} ->
          Mint.HTTP.close(conn)
          {:ok, status, body}

        {:error, conn, reason} ->
          Mint.HTTP.close(conn)
          {:error, reason}
      end
    end
  end

  defp receive_response(conn, ref, acc) do
    case Mint.HTTP.recv(conn, 0, 15_000) do
      {:ok, conn, responses} ->
        acc =
          Enum.reduce(responses, acc, fn
            {:status, ^ref, status}, acc -> %{acc | status: status}
            {:data, ^ref, data}, acc -> %{acc | body: acc.body <> data}
            {:done, ^ref}, acc -> Map.put(acc, :done, true)
            _, acc -> acc
          end)

        if acc[:done],
          do: {:ok, conn, acc.status, acc.body},
          else: receive_response(conn, ref, acc)

      {:error, conn, reason, _responses} ->
        {:error, conn, reason}
    end
  end

  # The provider token (an ES256 JWT), kept for its 50 minutes.
  defp token do
    now = System.system_time(:second)

    case :persistent_term.get({__MODULE__, :token}, nil) do
      {token, made} when now - made < @token_ttl ->
        token

      _ ->
        token = sign(config(), now)
        :persistent_term.put({__MODULE__, :token}, {token, now})
        token
    end
  end

  @doc false
  def sign(%{key_file: key_file, key_id: key_id, team_id: team_id}, now) do
    [entry] = key_file |> File.read!() |> :public_key.pem_decode()
    key = :public_key.pem_entry_decode(entry)

    header = b64(Jason.encode!(%{alg: "ES256", kid: key_id}))
    claims = b64(Jason.encode!(%{iss: team_id, iat: now}))
    input = header <> "." <> claims

    # `:public_key` signs in DER; a JWT wants r and s side by side.
    der = :public_key.sign(input, :sha256, key)
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    input <> "." <> b64(<<r::256, s::256>>)
  end

  defp config do
    Application.get_env(:loom, __MODULE__, [])
    |> Map.new()
    |> Map.reject(fn {_, v} -> v in [nil, ""] end)
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end
