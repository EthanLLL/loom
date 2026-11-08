defmodule LoomWeb.Apps do
  @moduledoc """
  The web side of `Loom.Apps`: an app's page and its API, under
  `/apps/<name>/<token>/` — or `/apps/<name>/` with the app's key in
  `Authorization: Bearer`, or for anyone when the app is public (`auth`).

    * `api/*` is forwarded to the unix socket `.run/http.sock` in the app's
      directory, which systemd holds and starts the server behind on the first
      request; loom never knows whether it is up
    * anything else is a file in its `web/`

  Only a registered app is served: a directory nobody `put` is not an app.
  A private app's `authorization` stops here; a public app gets it, to check
  its own way.

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

  Except files: a reply with `x-loom-file: <path in the app's directory>` is
  answered with that file from disk, like nginx's `X-Accel-Redirect`, so the
  app decides who gets what and loom moves the bytes — with `Range`, which
  iOS needs to play a video at all. `web/` is served the same way.
  """
  import Plug.Conn

  @hop_by_hop ~w(connection keep-alive transfer-encoding content-length upgrade)
  @cookie "loom_app"

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: ["apps", name | rest]} = conn, opts) do
    own = Keyword.get(opts, :own_origin, false)

    conn =
      if own,
        do: conn |> own_origin() |> put_private(:apps_own_origin, true),
        else: sandboxed(conn)

    case authorize(conn, Loom.Apps.get(name), rest, own) do
      :error when own and conn.method in ["GET", "HEAD"] ->
        if Enum.join(rest, "/") in Loom.Apps.install_files(name),
          do: conn |> static(name, rest) |> halt(),
          else: conn |> send_resp(404, "not found") |> halt()

      {:ok, conn, rest} ->
        conn |> handle(name, rest) |> halt()

      {:redirect, conn, to} ->
        conn |> put_resp_header("location", to) |> send_resp(302, "") |> halt()

      :error ->
        conn |> send_resp(404, "not found") |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp authorize(_conn, nil, _rest, _own), do: :error
  defp authorize(conn, %{auth: "public"}, rest, _own), do: {:ok, conn, rest}

  defp authorize(conn, %{name: name}, rest, own) do
    case {get_req_header(conn, "authorization"), rest} do
      {["Bearer " <> key], _} ->
        if Loom.Apps.valid_key?(name, key),
          do: {:ok, delete_req_header(conn, "authorization"), rest},
          else: :error

      {[], [token | after_token]} ->
        cond do
          not Loom.Apps.valid_token?(name, token) -> by_cookie(conn, name, rest, own)
          own and conn.method == "GET" -> trade(conn, name, after_token)
          true -> {:ok, conn, after_token}
        end

      {[], []} ->
        by_cookie(conn, name, rest, own)

      _ ->
        :error
    end
  end

  # On the apps' own origin the signed link is traded for a cookie on the
  # app's path, and the page reloads without the token: its URL then outlives
  # the link, which is what a PWA's start_url and a bookmark need.
  defp trade(conn, name, rest) do
    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
    {:redirect, put_cookie(conn, name), "/apps/#{name}/" <> Enum.join(rest, "/") <> query}
  end

  # Renewed on every page load, so an app in use never logs out.
  defp by_cookie(conn, name, rest, true) do
    conn = fetch_cookies(conn)

    with value when is_binary(value) <- conn.req_cookies[@cookie],
         true <- Loom.Apps.valid_cookie?(name, value) do
      conn = if match?(["api" | _], rest), do: conn, else: put_cookie(conn, name)
      {:ok, conn, rest}
    else
      _ -> :error
    end
  end

  defp by_cookie(_conn, _name, _rest, false), do: :error

  defp put_cookie(conn, name) do
    put_resp_cookie(conn, @cookie, Loom.Apps.cookie(name),
      path: "/apps/#{name}/",
      max_age: Loom.Apps.max_age(),
      http_only: true,
      secure: String.starts_with?(Loom.Apps.origin() || "", "https:"),
      same_site: "Lax"
    )
  end

  # A page fetching from an opaque origin sends a preflight for JSON; it is
  # answered here, not by the app.
  defp handle(%Plug.Conn{method: "OPTIONS"} = conn, _name, ["api" | _]) do
    conn
    |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, PATCH, DELETE")
    |> put_resp_header("access-control-allow-headers", "content-type, authorization")
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
      conn |> put_resp_content_type(MIME.from_path(path), nil) |> file(200, path)
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
      for(
        h <- ~w(content-type accept authorization),
        v <- get_req_header(conn, h),
        do: "#{h}: #{v}\r\n"
      ),
      app_cookies(conn),
      "content-length: #{byte_size(body)}\r\n\r\n",
      body
    ]

    with {:ok, reply} <- exchange(socket, request),
         {:ok, status, headers, resp_body} <- parse(reply) do
      conn =
        headers
        |> Enum.reject(fn {k, _} -> k in @hop_by_hop or k == "x-loom-file" end)
        |> Enum.reduce(conn, fn {k, v}, conn -> put_resp_header(conn, k, v) end)

      case List.keyfind(headers, "x-loom-file", 0) do
        nil -> send_resp(conn, status, resp_body)
        {_, path} -> app_file(conn, name, status, path)
      end
    else
      _ -> send_resp(conn, 502, ~s({"error":"app #{name} is not running"}))
    end
  end

  # On its own origin an app has cookies like any site; loom's is not its.
  defp app_cookies(%Plug.Conn{private: %{apps_own_origin: true}} = conn) do
    cookies =
      for header <- get_req_header(conn, "cookie"),
          pair <- String.split(header, ";"),
          pair = String.trim(pair),
          pair != "",
          not String.starts_with?(pair, @cookie <> "="),
          do: pair

    if cookies == [], do: [], else: "cookie: #{Enum.join(cookies, "; ")}\r\n"
  end

  defp app_cookies(_conn), do: []

  # Inside the app's directory only: the path is often built from a request,
  # and a slip there should be a 404, not someone's ~/.ssh.
  defp app_file(conn, name, status, path) do
    root = Path.expand(Loom.Apps.dir(name))
    full = Path.expand(path, root)

    cond do
      not String.starts_with?(full, root <> "/") or not File.regular?(full) ->
        send_resp(conn, 404, ~s({"error":"x-loom-file: no such file in the app"}))

      get_resp_header(conn, "content-type") == [] ->
        conn |> put_resp_content_type(MIME.from_path(full), nil) |> file(status, full)

      true ->
        file(conn, status, full)
    end
  end

  # One `Range: bytes=` span when asked for; anything fancier gets the whole
  # file, which a client must accept.
  defp file(conn, status, path) do
    size = File.stat!(path).size
    conn = put_resp_header(conn, "accept-ranges", "bytes")

    case range(get_req_header(conn, "range"), size) do
      {first, last} when status == 200 ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> send_file(206, path, first, last - first + 1)

      :unsatisfiable when status == 200 ->
        conn |> put_resp_header("content-range", "bytes */#{size}") |> send_resp(416, "")

      _ ->
        send_file(conn, status, path)
    end
  end

  defp range(["bytes=" <> spec], size) do
    with false <- String.contains?(spec, ","),
         [from, to] <- String.split(String.trim(spec), "-", parts: 2),
         {:ok, first, last} <- span(from, to, size) do
      if first <= last and first < size, do: {first, min(last, size - 1)}, else: :unsatisfiable
    else
      _ -> nil
    end
  end

  defp range(_, _), do: nil

  defp span("", suffix, size) do
    with {n, ""} when n > 0 <- Integer.parse(suffix), do: {:ok, max(size - n, 0), size - 1}
  end

  defp span(from, "", size) do
    with {first, ""} <- Integer.parse(from), do: {:ok, first, size - 1}
  end

  defp span(from, to, _size) do
    with {first, ""} <- Integer.parse(from),
         {last, ""} <- Integer.parse(to),
         do: {:ok, first, last}
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

  # Its own origin is the isolation: no sandbox, and nothing cross-origin to allow.
  defp own_origin(conn) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("cache-control", "no-cache, no-transform")
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
