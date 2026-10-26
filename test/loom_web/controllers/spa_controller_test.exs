defmodule LoomWeb.SpaControllerTest do
  @moduledoc """
  The app serves its own frontend.

  Worth a test because the failure is silent and total: nothing in front of
  Phoenix serves static files any more, so a missing `Plug.Static` or a missing
  root route means the API works perfectly and the browser gets nothing.
  """
  use LoomWeb.ConnCase, async: true

  @index Path.join(:code.priv_dir(:loom), "static/index.html")

  test "a static asset is served from the release", %{conn: conn} do
    # `favicon.ico` is checked in, so this holds in a fresh clone where the
    # frontend has not been built.
    conn = get(conn, "/favicon.ico")
    assert conn.status == 200
  end

  test "unversioned static files are cached for a day", %{conn: conn} do
    conn = get(conn, "/favicon.ico")
    assert get_resp_header(conn, "cache-control") == ["public, max-age=86400"]
  end

  test "fingerprinted assets are cached for good", %{conn: conn} do
    # A name of its own, so a real build's files are never touched.
    path = Path.join(:code.priv_dir(:loom), "static/assets/cache-test-0000.js")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "1")
    on_exit(fn -> File.rm(path) end)

    conn = get(conn, "/assets/cache-test-0000.js")
    assert conn.status == 200

    assert get_resp_header(conn, "cache-control") == [
             "public, max-age=31536000, immutable"
           ]
  end

  test "an asset not in the allowlist is not reachable", %{conn: conn} do
    # `only:` is the whole reason `priv/` is not browsable.
    assert get(conn, "/agent_sessions/anything.json").status == 404
  end

  describe "with a built frontend" do
    setup do
      if File.regular?(@index) do
        :ok
      else
        File.mkdir_p!(Path.dirname(@index))
        File.write!(@index, "<!doctype html><title>loom</title>")
        on_exit(fn -> File.rm(@index) end)
      end
    end

    test "/ returns the app shell, uncached", %{conn: conn} do
      conn = get(conn, "/")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"
      # The shell names fingerprinted assets, so a cached one would point at
      # files the next release no longer has.
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end

    test "an unknown path is a 404, not the app shell", %{conn: conn} do
      # No client-side router, so a catch-all would turn every typo — and
      # every missing API route — into a silent 200.
      assert get(conn, "/nope").status == 404
    end
  end

  test "without a build it says so instead of failing obscurely", %{conn: conn} do
    if File.regular?(@index) do
      File.rename!(@index, @index <> ".bak")
      on_exit(fn -> File.rename(@index <> ".bak", @index) end)
    end

    assert %{"hint" => hint} = conn |> get("/") |> json_response(404)
    assert hint =~ "assets.deploy"
  end
end
