defmodule Loom.Turn.KVS do
  @moduledoc """
  TURN from Amazon Kinesis Video Streams: a signaling channel's TURN servers
  (GetSignalingChannelEndpoint, then GetIceServerConfig), with credentials
  that last five minutes. Only the relay is used; the offer and answer still
  go through Loom.

  Configured with the channel's ARN (`LOOM_TURN_KVS_CHANNEL`), which names
  its region and partition, and AWS credentials allowed those two calls on
  it: those of a profile in `~/.aws/config` (`LOOM_TURN_AWS_PROFILE`, its
  `credential_process` or keys in `~/.aws/credentials`, so IAM Roles
  Anywhere or SSO work as they do for the CLI), or else
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`.
  """

  @doc """
  `{:ok, servers, cache}` or `{:error, reason}`; `cache` (the channel's
  endpoint and the credentials, while they last) is handed back on the next
  call.
  """
  def ice_servers(config, cache) do
    arn = config[:kvs_channel]
    cache = cache || %{}

    with {:ok, region, domain} <- parse(arn),
         {:ok, creds} <- credentials(config[:aws_profile], cache[:creds]),
         {:ok, endpoint} <- endpoint(cache[:endpoint], arn, region, domain, creds),
         {:ok, %{"IceServerList" => list}} <-
           call(creds, region, endpoint <> "/v1/get-ice-server-config", %{
             "ChannelARN" => arn,
             "Service" => "TURN"
           }) do
      servers =
        for s <- list do
          # UDP only: the TCP and TLS ones would be chosen over a Loom
          # relay that is no slower, and cost relay minutes for it.
          urls = for u <- s["Uris"], String.starts_with?(u, "turn:"), do: u
          %{"urls" => urls, "username" => s["Username"], "credential" => s["Password"]}
        end

      {:ok, Enum.filter(servers, &(&1["urls"] != [])), %{endpoint: endpoint, creds: creds}}
    end
  end

  defp parse(arn) do
    case String.split(arn, ":") do
      ["arn", "aws-cn", "kinesisvideo", region | _] -> {:ok, region, "amazonaws.com.cn"}
      ["arn", "aws", "kinesisvideo", region | _] -> {:ok, region, "amazonaws.com"}
      _ -> {:error, "not a Kinesis Video Streams channel ARN: #{arn}"}
    end
  end

  defp endpoint(endpoint, _, _, _, _) when is_binary(endpoint), do: {:ok, endpoint}

  defp endpoint(nil, arn, region, domain, creds) do
    body = %{
      "ChannelARN" => arn,
      "SingleMasterChannelEndpointConfiguration" => %{
        "Protocols" => ["HTTPS"],
        "Role" => "MASTER"
      }
    }

    url = "https://kinesisvideo.#{region}.#{domain}/getSignalingChannelEndpoint"

    case call(creds, region, url, body) do
      {:ok, %{"ResourceEndpointList" => [%{"ResourceEndpoint" => e} | _]}} -> {:ok, e}
      {:ok, other} -> {:error, {:no_endpoint, other}}
      error -> error
    end
  end

  # A signed POST of `body` as JSON; the decoded answer.
  defp call(creds, region, url, body) do
    json = Jason.encode!(body)
    headers = sign(creds, region, "kinesisvideo", url, json)

    request =
      {String.to_charlist(url), for({k, v} <- headers, do: {~c"#{k}", ~c"#{v}"}),
       ~c"application/json", json}

    http = [timeout: 10_000, connect_timeout: 5_000, ssl: ssl_options()]

    case :httpc.request(:post, request, http, body_format: :binary) do
      {:ok, {{_, 200, _}, _, answer}} -> Jason.decode(answer)
      {:ok, {{_, status, _}, _, answer}} -> {:error, {status, answer}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # Signature Version 4, for one JSON POST with no query string.
  def sign(creds, region, service, url, body, now \\ DateTime.utc_now()) do
    uri = URI.parse(url)
    stamp = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    date = binary_part(stamp, 0, 8)

    headers =
      [{"content-type", "application/json"}, {"host", uri.host}, {"x-amz-date", stamp}] ++
        if(creds.token, do: [{"x-amz-security-token", creds.token}], else: [])

    signed = Enum.map_join(headers, ";", &elem(&1, 0))

    canonical =
      Enum.join(
        [
          "POST",
          uri.path || "/",
          "",
          Enum.map_join(headers, "", fn {k, v} -> "#{k}:#{v}\n" end),
          signed,
          hex(:crypto.hash(:sha256, body))
        ],
        "\n"
      )

    scope = "#{date}/#{region}/#{service}/aws4_request"

    to_sign =
      Enum.join(["AWS4-HMAC-SHA256", stamp, scope, hex(:crypto.hash(:sha256, canonical))], "\n")

    key =
      Enum.reduce([date, region, service, "aws4_request"], "AWS4" <> creds.secret, &hmac(&2, &1))

    auth =
      "AWS4-HMAC-SHA256 Credential=#{creds.key}/#{scope}, SignedHeaders=#{signed}, " <>
        "Signature=#{hex(hmac(key, to_sign))}"

    [{"authorization", auth} | List.keydelete(headers, "content-type", 0)]
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hex(bin), do: Base.encode16(bin, case: :lower)

  # ── Credentials ──────────────────────────────────────────────────────

  # Kept until five minutes before they expire; keys with no expiry, always.
  defp credentials(profile, %{expires: e} = creds) do
    if is_nil(e) or System.os_time(:second) < e - 300,
      do: {:ok, creds},
      else: credentials(profile, nil)
  end

  defp credentials(profile, _) when is_binary(profile) and profile != "" do
    config = ini(Path.expand("~/.aws/config"))
    section = if profile == "default", do: "default", else: "profile " <> profile

    case config[section] do
      %{"credential_process" => cmd} -> process(cmd)
      %{} -> keys(ini(Path.expand("~/.aws/credentials"))[profile])
      nil -> keys(ini(Path.expand("~/.aws/credentials"))[profile])
    end
  end

  defp credentials(_, _) do
    keys(%{
      "aws_access_key_id" => System.get_env("AWS_ACCESS_KEY_ID"),
      "aws_secret_access_key" => System.get_env("AWS_SECRET_ACCESS_KEY"),
      "aws_session_token" => System.get_env("AWS_SESSION_TOKEN")
    })
  end

  defp keys(%{"aws_access_key_id" => k, "aws_secret_access_key" => s} = m)
       when is_binary(k) and is_binary(s),
       do: {:ok, %{key: k, secret: s, token: m["aws_session_token"], expires: nil}}

  defp keys(_), do: {:error, "no AWS credentials for Kinesis Video Streams"}

  defp process(cmd) do
    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {out, 0} ->
        with {:ok, %{"AccessKeyId" => k, "SecretAccessKey" => s} = m} <- Jason.decode(out) do
          expires =
            case DateTime.from_iso8601(m["Expiration"] || "") do
              {:ok, t, _} -> DateTime.to_unix(t)
              _ -> nil
            end

          {:ok, %{key: k, secret: s, token: m["SessionToken"], expires: expires}}
        else
          _ -> {:error, "credential_process gave no credentials"}
        end

      {out, status} ->
        {:error, "credential_process exited #{status}: #{String.slice(out, 0, 200)}"}
    end
  end

  # An AWS config or credentials file: %{section => %{key => value}}.
  defp ini(path) do
    case File.read(path) do
      {:ok, text} ->
        text
        |> String.split("\n")
        |> Enum.reduce({nil, %{}}, fn line, {section, acc} ->
          line = String.trim(line)

          cond do
            line == "" or String.starts_with?(line, ["#", ";"]) ->
              {section, acc}

            String.starts_with?(line, "[") ->
              name =
                line |> String.trim_leading("[") |> String.trim_trailing("]") |> String.trim()

              {name, Map.put_new(acc, name, %{})}

            section != nil and String.contains?(line, "=") ->
              [k, v] = String.split(line, "=", parts: 2)
              {section, put_in(acc, [section, String.trim(k)], String.trim(v))}

            true ->
              {section, acc}
          end
        end)
        |> elem(1)

      _ ->
        %{}
    end
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
