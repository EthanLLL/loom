defmodule LoomWeb.AppsEndpointTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint LoomWeb.AppsEndpoint

  setup do
    name = "own-#{System.unique_integer([:positive])}"
    root = Loom.Apps.dir(name)
    File.mkdir_p!(Path.join(root, "web"))
    File.write!(Path.join([root, "web", "index.html"]), "<h1>own</h1>")
    {:ok, app} = Loom.Apps.put(name, %{title: "Own"})

    on_exit(fn ->
      Loom.Apps.delete(name)
      File.rm_rf!(root)
    end)

    %{name: name, url: app.url}
  end

  test "its url is absolute, on the apps' origin", %{name: name, url: url} do
    assert url =~ ~r"^https://apps\.test/apps/#{name}/[^/]+/$"
  end

  test "the signed link becomes a cookie on the app's path, and the page has no sandbox",
       %{name: name, url: url} do
    path = String.replace_prefix(url, "https://apps.test", "")
    conn = get(build_conn(), path <> "?x=1")
    assert redirected_to(conn, 302) == "/apps/#{name}/?x=1"
    cookie = conn.resp_cookies["loom_app"]
    assert cookie.path == "/apps/#{name}/"
    assert cookie.http_only and cookie.secure and cookie.same_site == "Lax"

    conn = build_conn() |> put_req_cookie("loom_app", cookie.value) |> get("/apps/#{name}/")
    assert conn.resp_body == "<h1>own</h1>"
    assert get_resp_header(conn, "content-security-policy") == []
    assert conn.resp_cookies["loom_app"], "renewed on a page load"
  end

  test "without the cookie, or with another app's, it is a 404", %{name: name} do
    assert get(build_conn(), "/apps/#{name}/").status == 404

    other = build_conn() |> put_req_cookie("loom_app", Loom.Apps.cookie("other"))
    assert get(other, "/apps/#{name}/").status == 404
  end

  test "loom's page libraries are here, at the same path" do
    File.mkdir_p!(Application.app_dir(:loom, "priv/static/vendor/t"))
    File.write!(Application.app_dir(:loom, "priv/static/vendor/t/x.js"), "x")
    on_exit(fn -> File.rm_rf!(Application.app_dir(:loom, "priv/static/vendor/t")) end)
    assert get(build_conn(), "/vendor/t/x.js").resp_body == "x"
  end

  test "what installing it needs is open; nothing else is", %{name: name} do
    web = Path.join(Loom.Apps.dir(name), "web")
    File.write!(Path.join(web, "favicon.svg"), "<svg/>")
    File.write!(Path.join(web, "i.png"), "png")
    File.write!(Path.join(web, "data.json"), "{}")
    File.write!(Path.join(web, "touch.png"), "png")

    File.write!(
      Path.join(web, "index.html"),
      ~s(<link rel="icon" href="favicon.svg"><link rel="apple-touch-icon" href="touch.png">)
    )

    File.write!(
      Path.join(web, "manifest.webmanifest"),
      ~s({"icons": [{"src": "./i.png"}, {"src": "../app.toml"}, {"src": "https://x/y.png"}]})
    )

    for path <- ["manifest.webmanifest", "i.png", "favicon.svg", "touch.png"],
        do: assert(get(build_conn(), "/apps/#{name}/#{path}").status == 200, path)

    for path <- ["data.json", "index.html", "", "../app.toml"],
        do: assert(get(build_conn(), "/apps/#{name}/#{path}").status == 404, path)
  end

  test "nothing of loom's is here" do
    for path <- ["/", "/api/agents", "/socket/websocket", "/manifest.webmanifest"] do
      assert get(build_conn(), path).status == 404
    end
  end

  test "the app's own cookies reach its server; loom's does not", %{name: name} do
    root = Loom.Apps.dir(name)
    sock = Path.join([root, ".run", "http.sock"])
    File.mkdir_p!(Path.dirname(sock))
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, sock}, active: false])
    test = self()

    spawn_link(fn ->
      {:ok, c} = :gen_tcp.accept(listen)
      {:ok, req} = :gen_tcp.recv(c, 0, 1_000)
      send(test, {:request, req})
      :gen_tcp.send(c, "HTTP/1.0 200 OK\r\nset-cookie: s=2; Path=/apps/#{name}/\r\n\r\nok")
      :gen_tcp.close(c)
    end)

    conn =
      build_conn()
      |> put_req_header("cookie", "loom_app=#{Loom.Apps.cookie(name)}; s=1")
      |> get("/apps/#{name}/api/me")

    assert conn.status == 200
    assert get_resp_header(conn, "set-cookie") == ["s=2; Path=/apps/#{name}/"]
    assert_received {:request, req}
    assert req =~ "cookie: s=1\r\n"
    refute req =~ "loom_app"
  end

  test "a public app is open", %{name: name} do
    {:ok, app} = Loom.Apps.put(name, %{auth: "public"})
    assert app.url == "https://apps.test/apps/#{name}/"
    assert get(build_conn(), "/apps/#{name}/").resp_body == "<h1>own</h1>"
  end
end
