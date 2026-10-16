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

    authed = put_req_header(conn, "authorization", "Bearer " <> Loom.Auth.mint_token())
    base = json_response(post(authed, "/api/agents/#{id}/canvas"), 200)["base"]
    {:ok, conn: conn, id: id, base: base}
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
end
