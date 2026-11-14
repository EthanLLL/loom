defmodule Loom.AppsTest do
  # The registry is one process over one file, with the app's own root.
  use ExUnit.Case, async: false

  alias Loom.Apps

  setup do
    tmp = Path.join(System.tmp_dir!(), "loom-apps-#{System.unique_integer([:positive])}")
    units = Path.join(tmp, "units")
    path = Path.join(tmp, "apps.json")
    name = :"apps_#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf!(tmp) end)
    start_supervised!({Apps, name: name, path: path, units: units, systemd: false})
    %{name: name, path: path, units: units}
  end

  defp page(app) do
    File.mkdir_p!(Path.join([Apps.dir(app), "web"]))
    File.write!(Path.join([Apps.dir(app), "web", "index.html"]), "<p>#{app}</p>")
    on_exit(fn -> File.rm_rf!(Apps.dir(app)) end)
    app
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  test "a new app goes last, titled by its name unless told", %{name: s} do
    a = page(uniq("a"))
    b = page(uniq("b"))
    assert {:ok, %{order: 1, title: ^a}} = Apps.put(a, %{}, s)
    assert {:ok, %{order: 2, title: "B"}} = Apps.put(b, %{title: "B"}, s)
    assert [%{name: ^a}, %{name: ^b, url: "https://apps.test/apps/" <> _}] = Apps.list(s)
  end

  test "refuses what it could not serve or run", %{name: s} do
    a = page(uniq("a"))
    assert {:error, _} = Apps.put("Bad_Name", %{}, s)
    assert {:error, "/" <> _} = Apps.put(uniq("nopage"), %{}, s)
    assert {:error, "a job needs a schedule"} = Apps.put(a, %{job: "true"}, s)
    assert {:error, "unknown keys: auth"} = Apps.put(a, %{auth: "public"}, s)
    assert {:error, "a port needs a server"} = Apps.put(a, %{port: 5200}, s)
    assert {:error, "proxy all needs a server"} = Apps.put(uniq("site"), %{proxy: "all"}, s)
    assert Apps.list(s) == []
  end

  test "a change keeps what it does not name; nil clears", %{name: s} do
    a = page(uniq("a"))
    {:ok, _} = Apps.put(a, %{title: "A", job: "python x.py", schedule: "hourly"}, s)
    assert {:ok, %{title: "A", job: "python x.py"}} = Apps.put(a, %{server: "node server.ts"}, s)

    assert {:ok, %{job: nil, schedule: nil, server: "node server.ts"}} =
             Apps.put(a, %{job: nil, schedule: nil}, s)
  end

  test "writes the units for what the app has, and removes them with it", %{name: s, units: units} do
    a = page(uniq("a"))

    {:ok, _} =
      Apps.put(
        a,
        %{server: "node server.ts", job: "python jobs/r.py", schedule: "*-*-* 00/4:00:00"},
        s
      )

    assert File.ls!(units) |> Enum.sort() ==
             Enum.sort([
               "app-#{a}.socket",
               "app-#{a}.service",
               "app-#{a}_server.service",
               "app-#{a}_job.service",
               "app-#{a}_job.timer"
             ])

    server = File.read!(Path.join(units, "app-#{a}_server.service"))
    assert server =~ ~s(ExecStart=/bin/sh -c "exec node server.ts")
    assert server =~ "WorkingDirectory=#{Apps.dir(a)}"
    assert File.read!(Path.join(units, "app-#{a}.service")) =~ "BindsTo=app-#{a}_server.service"
    assert File.read!(Path.join(units, "app-#{a}_job.timer")) =~ "OnCalendar=*-*-* 00/4:00:00"
    assert server =~ "MemoryMax=256M\n"

    assert {:error, "memory: a size like 512M or 2G"} = Apps.put(a, %{memory: "lots"}, s)
    {:ok, %{memory: "2G"}} = Apps.put(a, %{memory: "2G"}, s)
    assert File.read!(Path.join(units, "app-#{a}_server.service")) =~ "MemoryMax=2G\n"

    {:ok, _} = Apps.put(a, %{server: nil}, s)
    refute File.exists?(Path.join(units, "app-#{a}.socket"))

    assert :ok = Apps.delete(a, s)
    assert File.ls!(units) == []
    refute File.exists?(Apps.dir(a))

    assert [_] =
             File.ls!(Path.join(Apps.root(), ".trash"))
             |> Enum.filter(&String.starts_with?(&1, a <> "-"))
  end

  test "an app named like another's unit keeps its own units", %{name: s, units: units} do
    x = page(uniq("x"))
    xjob = page(x <> "-job")
    {:ok, _} = Apps.put(x, %{job: "true", schedule: "hourly"}, s)
    {:ok, _} = Apps.put(xjob, %{server: "node server.ts"}, s)

    assert File.read!(Path.join(units, "app-#{x}_job.service")) =~ "exec true"
    assert File.read!(Path.join(units, "app-#{xjob}.service")) =~ "systemd-socket-proxyd"

    assert :ok = Apps.delete(x, s)

    assert File.ls!(units) |> Enum.sort() ==
             Enum.sort([
               "app-#{xjob}.socket",
               "app-#{xjob}.service",
               "app-#{xjob}_server.service"
             ])
  end

  test "moves, and renumbers on delete", %{name: s} do
    [a, b, c] = Enum.map(~w(a b c), &page(uniq(&1)))
    for x <- [a, b, c], do: {:ok, _} = Apps.put(x, %{}, s)
    assert :ok = Apps.move(c, 1, s)
    assert Enum.map(Apps.list(s), &{&1.name, &1.order}) == [{c, 1}, {a, 2}, {b, 3}]
    assert :ok = Apps.delete(a, s)
    assert Enum.map(Apps.list(s), &{&1.name, &1.order}) == [{c, 1}, {b, 2}]
    assert {:error, :not_found} = Apps.move(a, 1, s)
  end

  test "reads back what it wrote", %{units: units} do
    path = Path.join(Path.dirname(units), "again.json")
    a = page(uniq("a"))
    name = :"apps_again_#{System.unique_integer([:positive])}"
    start_supervised!({Apps, name: name, path: path, units: units, systemd: false}, id: :again)
    {:ok, _} = Apps.put(a, %{title: "Kept"}, name)
    stop_supervised!(:again)
    start_supervised!({Apps, name: name, path: path, units: units, systemd: false}, id: :again2)
    assert [%{name: ^a, title: "Kept", order: 1}] = Apps.list(name)
  end

  test "its icon is the page's favicon", %{name: s} do
    a = page(uniq("a"))
    web = Path.join(Apps.dir(a), "web")
    {:ok, %{icon: nil}} = Apps.put(a, %{}, s)

    File.write!(Path.join(web, "favicon.png"), "png")
    assert [%{icon: icon}] = Apps.list(s)
    assert String.ends_with?(icon, "/favicon.png")

    File.mkdir_p!(Path.join(web, "img"))
    File.write!(Path.join(web, "img/mark.svg"), "<svg/>")

    File.write!(
      Path.join(web, "index.html"),
      ~s(<link rel="shortcut icon" href="/img/mark.svg?v=2">)
    )

    assert [%{icon: icon}] = Apps.list(s)
    assert String.ends_with?(icon, "/img/mark.svg")

    # Nothing outside web/, and no other site's.
    File.write!(
      Path.join(web, "index.html"),
      ~s(<link rel="icon" href="../server.ts"><link rel="icon" href="https://x/i.png">)
    )

    assert [%{icon: icon}] = Apps.list(s)
    assert String.ends_with?(icon, "/favicon.png")
  end

  test "a whole site needs no page; ports are the app's own", %{name: s, units: units} do
    site = uniq("site")
    on_exit(fn -> File.rm_rf!(Apps.dir(site)) end)
    File.mkdir_p!(Apps.dir(site))

    assert {:ok, %{proxy: "all", port: 5200, url: "https://apps.test/apps/" <> _}} =
             Apps.put(site, %{proxy: "all", server: "npm start", port: 5200}, s)

    unit = File.read!(Path.join(units, "app-#{site}_server.service"))
    assert unit =~ "Environment=PORT=5200"
    assert File.read!(Path.join(units, "app-#{site}.service")) =~ " 127.0.0.1:5200\n"

    b = page(uniq("b"))
    assert {:error, "port 5200 is another app's"} = Apps.put(b, %{server: "x", port: 5200}, s)
    assert {:error, "port: " <> _} = Apps.put(b, %{server: "x", port: "5201"}, s)
    assert {:error, "proxy: api or all"} = Apps.put(b, %{proxy: "some"}, s)
  end

  test "Caddy's config: a route per app, the server only where there is one" do
    a = page(uniq("a"))
    site = uniq("site")

    apps = %{
      a => %{name: a, proxy: "api", server: nil},
      site => %{name: site, proxy: "all", server: "npm start"}
    }

    config = Apps.caddy_config(%{apps: apps, caddy: "/x/caddy.json"})
    assert config.admin.listen == "unix//x/caddy-admin.sock|0600"
    routes = config.apps.http.servers.apps.routes
    json = Jason.encode!(routes)

    assert [%{path: ["/vendor/*"]}] = hd(routes).match
    assert %{handle: [%{handler: "static_response", status_code: 404}]} = List.last(routes)
    assert json =~ ~s("root":"#{Apps.dir(a)}/web")
    refute json =~ "/apps/#{a}/api/*"
    assert json =~ ~s("dial":"unix/#{Apps.dir(site)}/.run/http.sock")
    assert json =~ "X-Loom-File"
  end
end
