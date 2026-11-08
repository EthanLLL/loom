defmodule LoomWeb.AppsTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint LoomWeb.AppsEndpoint

  # The application's own registry, over the test root (config/test.exs).
  setup do
    name = "demo-#{System.unique_integer([:positive])}"
    root = Loom.Apps.dir(name)
    File.mkdir_p!(Path.join(root, "web"))
    File.mkdir_p!(Path.join(root, ".run"))
    File.write!(Path.join([root, "web", "index.html"]), "<h1>demo</h1>")
    {:ok, app} = Loom.Apps.put(name, %{title: "Demo App"})

    on_exit(fn ->
      Loom.Apps.delete(name)
      File.rm_rf!(root)
    end)

    # What a browser holds once the signed link has been opened.
    cookie = get(build_conn(), app.url).resp_cookies["loom_app"].value

    %{
      name: name,
      root: root,
      signed: app.url,
      base: "/apps/#{name}/",
      cookie: cookie,
      conn: signed_in(cookie)
    }
  end

  defp signed_in(cookie), do: build_conn() |> put_req_cookie("loom_app", cookie)

  test "serves web/ as a plain site, no sandbox", %{conn: conn, base: base} do
    conn = get(conn, base)
    assert conn.status == 200
    assert conn.resp_body == "<h1>demo</h1>"
    assert get_resp_header(conn, "content-security-policy") == []
  end

  test "loom's own origin serves no app", %{signed: signed} do
    path = String.replace_prefix(signed, "https://apps.test", "")

    assert Phoenix.ConnTest.dispatch(build_conn(), LoomWeb.Endpoint, :get, path).status == 404
  end

  test "adds the trailing slash relative URLs need", %{conn: conn, base: base} do
    conn = get(conn, String.trim_trailing(base, "/"))
    assert conn.status == 301
    assert get_resp_header(conn, "location") == [base]
  end

  test "rejects a token for another app, an unregistered one, and paths outside web/",
       %{conn: conn, base: base, name: name, signed: signed} do
    [token] = Regex.run(~r"/apps/#{name}/([^/]+)/$", signed, capture: :all_but_first)
    assert get(build_conn(), "/apps/other/" <> token).status == 404
    File.mkdir_p!(Path.join([Loom.Apps.root(), "stray", "web"]))
    File.write!(Path.join([Loom.Apps.root(), "stray", "web", "index.html"]), "x")
    assert get(build_conn(), Loom.Apps.url("stray")).status == 404
    assert get(conn, base <> "../app.toml").status == 404
  end

  test "forwards api/* with its body to the app's socket", %{conn: conn, base: base, root: root} do
    sock = Path.join([root, ".run", "http.sock"])

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, sock}, active: false, packet: :raw])

    test = self()

    spawn_link(fn ->
      {:ok, c} = :gen_tcp.accept(listen)
      {:ok, req} = :gen_tcp.recv(c, 0, 1_000)
      send(test, {:request, req})
      :gen_tcp.send(c, "HTTP/1.1 201 Created\r\ncontent-type: application/json\r\n\r\n{\"id\":1}")
      :gen_tcp.close(c)
    end)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(base <> "api/todos?x=1", ~s({"title":"t"}))

    assert conn.status == 201
    assert conn.resp_body == ~s({"id":1})
    assert_received {:request, "POST /api/todos?x=1 HTTP/1.0\r\n" <> rest}
    assert String.ends_with?(rest, ~s(\r\n\r\n{"title":"t"}))
  end

  test "a 502 when nothing listens", %{conn: conn, base: base} do
    assert get(conn, base <> "api/todos").status == 502
  end

  defp listen(root, reply \\ "HTTP/1.0 200 OK\r\n\r\nok") do
    sock = Path.join([root, ".run", "http.sock"])

    File.rm(sock)

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, sock}, active: false, packet: :raw])

    test = self()

    spawn_link(fn ->
      {:ok, c} = :gen_tcp.accept(listen)
      {:ok, req} = :gen_tcp.recv(c, 0, 1_000)
      send(test, {:request, req})
      :gen_tcp.send(c, reply)
      :gen_tcp.close(c)
    end)
  end

  test "web/ answers a byte range", %{conn: conn, base: base, cookie: cookie} do
    conn = conn |> put_req_header("range", "bytes=1-2") |> get(base)
    assert conn.status == 206
    assert conn.resp_body == "h1"
    assert get_resp_header(conn, "content-range") == ["bytes 1-2/13"]

    conn = signed_in(cookie) |> put_req_header("range", "bytes=-4") |> get(base)
    assert conn.resp_body == "/h1>"
    conn = signed_in(cookie) |> put_req_header("range", "bytes=99-") |> get(base)
    assert conn.status == 416
    conn = signed_in(cookie) |> put_req_header("range", "bytes=0-1,4-5") |> get(base)
    assert conn.status == 200
    assert get(signed_in(cookie), base).resp_headers |> List.keyfind("accept-ranges", 0)
  end

  test "x-loom-file: the app picks the file, loom sends it, ranges and all",
       %{conn: conn, base: base, root: root, cookie: cookie} do
    File.mkdir_p!(Path.join(root, "media"))
    File.write!(Path.join([root, "media", "clip.mp4"]), "0123456789")

    listen(
      root,
      "HTTP/1.0 200 OK\r\nx-loom-file: media/clip.mp4\r\ncontent-disposition: inline\r\n\r\n"
    )

    conn = conn |> put_req_header("range", "bytes=2-4") |> get(base <> "api/file?id=1")
    assert conn.status == 206
    assert conn.resp_body == "234"
    assert get_resp_header(conn, "content-type") == ["video/mp4"]
    assert get_resp_header(conn, "content-disposition") == ["inline"]
    assert get_resp_header(conn, "x-loom-file") == []

    listen(root, "HTTP/1.0 200 OK\r\nx-loom-file: media/clip.mp4\r\n\r\n")
    assert get(signed_in(cookie), base <> "api/file").resp_body == "0123456789"

    for escape <- ["../../etc/passwd", "/etc/passwd", "media/nope"] do
      listen(root, "HTTP/1.0 200 OK\r\nx-loom-file: #{escape}\r\n\r\n")
      assert get(signed_in(cookie), base <> "api/file").status == 404
    end
  end

  test "a key opens a private app without the signed path, and stays in loom",
       %{name: name, root: root} do
    {:ok, key} = Loom.Apps.key(name)
    listen(root)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> key)
      |> post("/apps/#{name}/api/ingest", %{})

    assert conn.status == 200
    assert_received {:request, req}
    refute req =~ ~r/authorization/i

    for auth <- ["Bearer nope", "Bearer " <> key <> "x"] do
      conn = build_conn() |> put_req_header("authorization", auth)
      assert post(conn, "/apps/#{name}/api/ingest", %{}).status == 404
    end

    assert get(build_conn(), "/apps/#{name}/").status == 404
    Loom.Apps.key(name, nil)
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> key)
    assert post(conn, "/apps/#{name}/api/ingest", %{}).status == 404
  end

  test "a public app is open, and its authorization is its own", %{name: name, root: root} do
    {:ok, _} = Loom.Apps.put(name, %{auth: "public"})
    assert get(build_conn(), "/apps/#{name}/").resp_body == "<h1>demo</h1>"
    assert get(build_conn(), "/apps/#{name}").status == 301
    listen(root)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer mine")
      |> get("/apps/#{name}/api/me")

    assert conn.status == 200
    assert_received {:request, "GET /api/me HTTP/1.0\r\n" <> rest}
    assert rest =~ "authorization: Bearer mine\r\n"
  end
end
