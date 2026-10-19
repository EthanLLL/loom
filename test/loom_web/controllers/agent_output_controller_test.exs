defmodule LoomWeb.AgentOutputControllerTest do
  @moduledoc """
  The download endpoint: authenticated, and only ever this session's outputs.
  """
  # Not async: the stub has a fixed name and the backend map is global config.
  use LoomWeb.ConnCase, async: false

  alias Loom.Agent
  alias Loom.Agent.Store
  alias Loom.BackendStub

  setup %{conn: conn} do
    data_dir = Path.join(System.tmp_dir!(), "loom-dl-#{System.unique_integer([:positive])}")
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

    id = "a_dl#{System.unique_integer([:positive])}"
    {:ok, _pid} = Agent.start_session(id, backend: :claude_code)

    path = Path.join([Store.output_dir(id), "deck", "季度 report.pptx"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "slides")

    authed = put_req_header(conn, "authorization", "Bearer " <> Loom.Auth.mint_token())
    {:ok, conn: conn, authed: authed, id: id}
  end

  test "serves the file as a download", %{authed: conn, id: id} do
    conn = get(conn, "/api/agents/#{id}/output/deck/#{URI.encode("季度 report.pptx")}")

    assert conn.status == 200
    assert conn.resp_body == "slides"
    [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
  end

  test "needs the token", %{conn: conn, id: id} do
    conn = get(conn, "/api/agents/#{id}/output/deck/x.pptx")
    assert conn.status == 401
  end

  test "will not leave the output directory", %{authed: conn, id: id} do
    # Both encoded and literal: the router decodes segments before we see them.
    for path <- ["..%2Fmeta.json", "deck/..%2F..%2Fmeta.json", "%2Fetc%2Fpasswd"] do
      assert get(conn, "/api/agents/#{id}/output/#{path}").status == 404
    end
  end

  test "an unknown session is a 404, not a path", %{authed: conn} do
    assert get(conn, "/api/agents/..%2F..%2Fetc/output/passwd").status == 404
    assert get(conn, "/api/agents/a_nope/output/deck/x.pptx").status == 404
  end

  describe "a directory as a zip" do
    test "holds the directory's files under its own name", %{authed: conn, id: id} do
      dir = Path.join(Store.output_dir(id), "manga")
      File.mkdir_p!(Path.join(dir, "images"))
      File.write!(Path.join(dir, "index.html"), "<p>hi</p>")
      File.write!(Path.join(dir, "images/第1页.jpg"), "jpg")
      File.write!(Path.join(dir, ".hidden"), "no")

      conn = get(conn, "/api/agents/#{id}/zip/manga")
      assert conn.status == 200
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "manga.zip"

      {:ok, entries} = :zip.unzip(conn.resp_body, [:memory])
      names = entries |> Enum.map(fn {name, _} -> List.to_string(name) end) |> Enum.sort()
      assert names == ["manga/images/第1页.jpg", "manga/index.html"]
    end

    test "only directories inside, and only with the token", %{conn: conn, authed: authed, id: id} do
      assert get(conn, "/api/agents/#{id}/zip/deck").status == 401

      for path <- ["..", "..%2F..", "deck/%E5%AD%A3%E5%BA%A6%20report.pptx", "missing"] do
        assert get(authed, "/api/agents/#{id}/zip/#{path}").status == 404, path
      end
    end
  end

  describe "the file browser's tree" do
    test "lists attachments and outputs, skipping hidden files", %{authed: conn, id: id} do
      files = Store.files_dir(id)
      File.mkdir_p!(files)
      File.write!(Path.join(files, "shot.png"), "png")
      File.write!(Path.join(files, ".DS_Store"), "x")
      File.write!(Path.join(Store.output_dir(id), "~$lock.xlsx"), "x")

      body = conn |> get("/api/agents/#{id}/tree") |> json_response(200)

      assert [%{"path" => "shot.png", "size" => 3, "mtime" => mtime}] = body["files"]
      assert is_integer(mtime)
      assert [%{"path" => "deck/季度 report.pptx", "size" => 6}] = body["output"]
    end

    test "is empty for a session with nothing yet, and needs the token", %{
      conn: conn,
      authed: authed,
      id: id
    } do
      File.rm_rf!(Store.output_dir(id))

      assert %{"files" => [], "output" => []} =
               authed |> get("/api/agents/#{id}/tree") |> json_response(200)

      assert get(conn, "/api/agents/#{id}/tree").status == 401
      assert get(authed, "/api/agents/a_nope/tree").status == 404
    end
  end
end
