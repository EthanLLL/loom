defmodule LoomWeb.Apps do
  @moduledoc """
  The web side of `Loom.Apps`: an app's page and its API, under
  `/apps/<name>/<token>/`.

    * `api/*` is forwarded to the unix socket `.run/http.sock` in the app's
      directory, which systemd holds and starts the server behind on the first
      request; loom never knows whether it is up
    * anything else is a file in its `web/`

  Only a registered app is served: a directory nobody `put` is not an app.

  ## Before `Plug.Parsers`

  A plug in the endpoint rather than a route: the body has to reach the app as
  it was sent, and the parsers would have consumed it.

  ## Hostile, like the canvas

  The code is model output, so it gets the canvas's treatment: a
  `sandbox` CSP without `allow-same-origin`, so its script never sees loom's
  origin and the login token there. The credential is a signed token in the
  path, scoped to one app (`Loom.Apps.url/1`), so the page's relative URLs
  (`api/todos`) carry it, and a link to the app can be bookmarked.

  ## The forwarding

  HTTP/1.0 over the socket, one request per connection: the reply then has no
  chunking and ends when the app closes, so reading it needs no HTTP client.
  Buffered, not streamed — nothing an app does today needs more.
  """
  import Plug.Conn

  @hop_by_hop ~w(connection keep-alive transfer-encoding content-length upgrade)

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: ["apps", name, token | rest]} = conn, _opts) do
    with true <- Loom.Apps.valid_token?(name, token),
         %{} <- Loom.Apps.get(name) do
      conn |> sandboxed() |> handle(name, rest) |> halt()
    else
      _ -> conn |> sandboxed() |> send_resp(404, "not found") |> halt()
    end
  end

  def call(conn, _opts), do: conn

  # A page fetching from an opaque origin sends a preflight for JSON; it is
  # answered here, not by the app.
  defp handle(%Plug.Conn{method: "OPTIONS"} = conn, _name, ["api" | _]) do
    conn
    |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, PATCH, DELETE")
    |> put_resp_header("access-control-allow-headers", "content-type")
    |> put_resp_header("access-control-max-age", "86400")
    |> send_resp(204, "")
  end

  defp handle(conn, name, ["api" | _] = rest), do: forward(conn, name, rest)

  # Without the trailing slash the page's relative URLs would drop the token.
  defp handle(conn, name, []) do
    if String.ends_with?(conn.request_path, "/"),
      do: static(conn, name, []),
      else: conn |> put_resp_header("location", conn.request_path <> "/") |> send_resp(301, "")
  end

  defp handle(conn, name, rest), do: static(conn, name, rest)

  defp static(conn, name, rest) do
    root = Path.join(Loom.Apps.dir(name), "web")
    path = Path.expand(Path.join([root | rest]))
    path = if File.dir?(path), do: Path.join(path, "index.html"), else: path

    if String.starts_with?(path, root <> "/") and File.regular?(path) do
      conn |> put_resp_content_type(MIME.from_path(path), nil) |> send_file(200, path)
    else
      send_resp(conn, 404, "not found")
    end
  end

  defp forward(conn, name, rest) do
    socket = Path.join([Loom.Apps.dir(name), ".run", "http.sock"])
    {:ok, body, conn} = read_all(conn, "")
    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string

    request = [
      "#{conn.method} /#{Enum.join(rest, "/")}#{query} HTTP/1.0\r\n",
      "host: #{name}\r\n",
      for(h <- ~w(content-type accept), v <- get_req_header(conn, h), do: "#{h}: #{v}\r\n"),
      "content-length: #{byte_size(body)}\r\n\r\n",
      body
    ]

    with {:ok, reply} <- exchange(socket, request),
         {:ok, status, headers, resp_body} <- parse(reply) do
      headers
      |> Enum.reject(fn {k, _} -> k in @hop_by_hop end)
      |> Enum.reduce(conn, fn {k, v}, conn -> put_resp_header(conn, k, v) end)
      |> send_resp(status, resp_body)
    else
      _ -> send_resp(conn, 502, ~s({"error":"app #{name} is not running"}))
    end
  end

  defp read_all(conn, acc) do
    case read_body(conn) do
      {:ok, data, conn} -> {:ok, acc <> data, conn}
      {:more, data, conn} -> read_all(conn, acc <> data)
    end
  end

  defp exchange(socket, request) do
    with {:ok, sock} <- :gen_tcp.connect({:local, socket}, 0, [:binary, active: false], 5_000) do
      try do
        with :ok <- :gen_tcp.send(sock, request), do: recv_all(sock, [])
      after
        :gen_tcp.close(sock)
      end
    end
  end

  # The app closing the connection is the end of the reply.
  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 30_000) do
      {:ok, data} -> recv_all(sock, [acc | data])
      {:error, :closed} -> {:ok, IO.iodata_to_binary(acc)}
      {:error, _} = error -> error
    end
  end

  defp parse(reply) do
    with [head, body] <- :binary.split(reply, "\r\n\r\n"),
         [status_line | lines] <- String.split(head, "\r\n"),
         [_version, code | _] <- String.split(status_line, " ", parts: 3),
         {status, ""} <- Integer.parse(code) do
      headers =
        for line <- lines,
            [k, v] <- [String.split(line, ":", parts: 2)],
            do: {String.downcase(String.trim(k)), String.trim(v)}

      {:ok, status, headers, body}
    else
      _ -> :error
    end
  end

  defp sandboxed(conn) do
    conn
    |> put_resp_header(
      "content-security-policy",
      "sandbox allow-scripts allow-forms allow-popups allow-modals allow-downloads"
    )
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    # `no-transform` keeps Cloudflare from injecting its analytics beacon,
    # which on an opaque origin fails CORS on every report and fills the console.
    |> put_resp_header("cache-control", "no-cache, no-transform")
  end
end
