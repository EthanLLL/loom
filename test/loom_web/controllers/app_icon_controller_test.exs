defmodule LoomWeb.AppIconControllerTest do
  # The app's registry is the global one.
  use LoomWeb.ConnCase, async: false

  alias Loom.Apps

  setup do
    name = "icon-#{System.unique_integer([:positive])}"
    web = Path.join(Apps.dir(name), "web")
    File.mkdir_p!(web)
    File.write!(Path.join(web, "index.html"), "<p>x</p>")
    File.write!(Path.join(web, "favicon.svg"), "<svg/>")

    on_exit(fn ->
      Apps.delete(name)
      File.rm_rf!(Apps.dir(name))
    end)

    {:ok, app} = Apps.put(name, %{})
    %{name: name, icon: app.icon}
  end

  test "serves the registry's copy, a picture cached for good, with no token", %{
    conn: conn,
    icon: icon
  } do
    conn = get(conn, icon)
    assert response(conn, 200) == "<svg/>"
    assert response_content_type(conn, :svg) =~ "image/svg+xml"
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "sandbox"
  end

  test "only an app's current icon", %{conn: conn, name: name} do
    assert conn |> get("/app-icons/#{name}/0000000000000000.svg") |> response(404)
    assert conn |> get("/app-icons/nobody/0000000000000000.svg") |> response(404)
    assert conn |> get("/app-icons/#{name}/..%2F..%2Fapps.json") |> response(404)
  end
end
