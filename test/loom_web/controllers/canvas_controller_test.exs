defmodule LoomWeb.CanvasControllerTest do
  @moduledoc """
  The canvas serves agent-written pages to an iframe without the bearer token,
  so the signed path is the whole of the access check, and the sandbox header
  is what keeps a page's script away from loom itself.
  """
  # Not async: the stub has a fixed name and the backend map is global config.
  use LoomWeb.ConnCase, async: false

  alias Loom.Agent
  alias Loom.Agent.Store
  alias Loom.BackendStub

  setup %{conn: conn} do
    data_dir = Path.join(System.tmp_dir!(), "loom-cv-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:loom, Loom.Agent, [])

    Application.put_env(
      :loom,
      Loom.Agent,
      previous
      |> Keyword.put(:data_dir, data_dir)
      |> Keyword.put(:backends, %{claude_code: BackendStub, codex: BackendStub})
    )

    start_supervised!({BackendStub, notify: self()})

    on_exit(fn ->
      for %{id: id} <- Agent.list_sessions(), do: Agent.stop_session(id)
      Process.sleep(50)
      Application.put_env(:loom, Loom.Agent, previous)
      File.rm_rf(data_dir)
    end)

    id = "a_cv#{System.unique_integer([:positive])}"
    {:ok, _pid} = Agent.start_session(id, backend: :claude_code)

    out = Store.output_dir(id)
    File.mkdir_p!(Path.join(out, "gallery/img"))
    File.write!(Path.join(out, "gallery/index.html"), "<img src=img/1.png>")
    File.write!(Path.join(out, "gallery/img/1.png"), "png")
    File.write!(Path.join(out, "run.log"), "line")
    File.write!(Path.join(out, "data.json"), "{}")
    File.write!(Path.join(out, "clip.mp4"), "0123456789")

    authed = put_req_header(conn, "authorization", "Bearer " <> Loom.Auth.mint_token())
    File.mkdir_p!(Store.files_dir(id))
    File.write!(Path.join(Store.files_dir(id), "截屏 1.png"), "shot")

    resp = json_response(post(authed, "/api/agents/#{id}/canvas"), 200)
    {:ok, conn: conn, id: id, base: resp["base"], files: resp["files"]}
  end

  test "the prefix needs the token to get", %{conn: conn, id: id, base: base} do
    assert post(conn, "/api/agents/#{id}/canvas").status == 401
    assert base =~ ~r"^/canvas/#{id}/[^/]+/$"
  end

  test "serves a page and its assets by relative path", %{conn: conn, base: base} do
    page = get(conn, base <> "gallery/index.html")
    assert page.status == 200
    assert page.resp_body =~ "img/1.png"
    assert [type] = get_resp_header(page, "content-type")
    assert type =~ "text/html"

    assert get(conn, base <> "gallery/img/1.png").resp_body == "png"
    # A directory means its index.html.
    assert get(conn, base <> "gallery").resp_body =~ "<img"
  end

  test "every response is sandboxed and leaks nothing onward", %{conn: conn, base: base} do
    for path <- ["gallery/index.html", "missing.html"] do
      resp = get(conn, base <> path)
      [csp] = get_resp_header(resp, "content-security-policy")
      assert csp =~ "sandbox"
      refute csp =~ "allow-same-origin"
      assert get_resp_header(resp, "referrer-policy") == ["no-referrer"]
    end
  end

  test "logs and data display as text instead of downloading", %{conn: conn, base: base} do
    assert [type] = get_resp_header(get(conn, base <> "run.log"), "content-type")
    assert type =~ "text/plain"
    assert [json] = get_resp_header(get(conn, base <> "data.json"), "content-type")
    assert json =~ "application/json"
  end

  test "a token is for one session only", %{conn: conn, base: base} do
    other = "a_cv_other"
    {:ok, _} = Agent.start_session(other, backend: :claude_code)
    File.mkdir_p!(Store.output_dir(other))
    File.write!(Path.join(Store.output_dir(other), "x.txt"), "theirs")

    [_, "canvas", _id, token, _] = String.split(base, "/")
    assert get(conn, "/canvas/#{other}/#{token}/x.txt").status == 404
    assert get(conn, "/canvas/#{other}/forged/x.txt").status == 404
  end

  test "will not leave the output directory", %{conn: conn, base: base} do
    for path <- ["..%2Fmeta.json", "gallery/..%2F..%2Fmeta.json", "%2Fetc%2Fpasswd"] do
      assert get(conn, base <> path).status == 404, path
    end
  end

  test "answers a byte range with just that slice", %{conn: conn, base: base} do
    ranged = fn spec -> conn |> put_req_header("range", spec) |> get(base <> "clip.mp4") end

    whole = get(conn, base <> "clip.mp4")
    assert whole.status == 200
    assert get_resp_header(whole, "accept-ranges") == ["bytes"]

    for {spec, body, content_range} <- [
          {"bytes=2-5", "2345", "bytes 2-5/10"},
          {"bytes=7-", "789", "bytes 7-9/10"},
          {"bytes=-3", "789", "bytes 7-9/10"},
          {"bytes=8-100", "89", "bytes 8-9/10"}
        ] do
      resp = ranged.(spec)
      assert {resp.status, resp.resp_body} == {206, body}, spec
      assert get_resp_header(resp, "content-range") == [content_range], spec
    end

    assert ranged.("bytes=10-").status == 416
    # Malformed or multi-range: the whole file, as if there were no header.
    for spec <- ["bytes=5-2", "bytes=x-", "bytes=0-1,4-5", "items=0-1"] do
      assert ranged.(spec).status == 200, spec
    end
  end

  test "serves the session's attachments, sandboxed, and nothing else", %{
    conn: conn,
    id: id,
    base: base,
    files: files
  } do
    [_, "canvas", ^id, token, _] = String.split(base, "/")
    assert files == "/canvas-files/#{id}/#{token}/"

    shot = get(conn, files <> URI.encode("截屏 1.png"))
    assert {shot.status, shot.resp_body} == {200, "shot"}
    assert [type] = get_resp_header(shot, "content-type")
    assert type =~ "image/png"
    [csp] = get_resp_header(shot, "content-security-policy")
    refute csp =~ "allow-same-origin"

    for name <- ["missing.png", "..%2Foutput%2Frun.log", "..%2Fmeta.json"] do
      assert get(conn, files <> name).status == 404, name
    end

    assert get(conn, "/canvas-files/#{id}/forged/" <> URI.encode("截屏 1.png")).status == 404
  end
end
