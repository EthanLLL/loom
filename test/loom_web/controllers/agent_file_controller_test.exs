defmodule LoomWeb.AgentFileControllerTest do
  @moduledoc """
  The upload endpoint.

  Attachments go over HTTP rather than the channel, so this is where the session
  id has to be checked: an unknown one must not create a directory, and it must
  certainly not be usable as a path.
  """
  # Not async: the stub has a fixed name and the backend map is global config.
  use LoomWeb.ConnCase, async: false

  alias Loom.Agent
  alias Loom.Agent.Store
  alias Loom.BackendStub

  setup %{conn: conn} do
    data_dir = Path.join(System.tmp_dir!(), "loom-up-#{System.unique_integer([:positive])}")
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

    id = "a_up#{System.unique_integer([:positive])}"
    {:ok, _pid} = Agent.start_session(id, backend: :claude_code)

    conn = put_req_header(conn, "authorization", "Bearer " <> Loom.Auth.mint_token())

    {:ok, conn: conn, id: id}
  end

  defp upload(filename, content, type \\ "text/plain") do
    path = Path.join(System.tmp_dir!(), "up-#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{filename: filename, path: path, content_type: type}
  end

  test "stores a file and reports its path", %{conn: conn, id: id} do
    conn = post(conn, ~p"/api/agents/#{id}/files", %{"files" => [upload("a.txt", "hello")]})

    assert %{"files" => [file]} = json_response(conn, 200)
    assert file["name"] == "a.txt"
    assert file["size"] == 5
    assert file["path"] == Path.join(Store.files_dir(id), "a.txt")
    assert File.read!(file["path"]) == "hello"
  end

  test "takes several files in one request", %{conn: conn, id: id} do
    conn =
      post(conn, ~p"/api/agents/#{id}/files", %{
        "files" => [upload("a.txt", "one"), upload("b.txt", "two")]
      })

    assert %{"files" => [_, _]} = json_response(conn, 200)
  end

  test "an unknown session is a 404 and writes nothing", %{conn: conn} do
    conn = post(conn, ~p"/api/agents/a_nope/files", %{"files" => [upload("a.txt", "hi")]})

    assert json_response(conn, 404)
    refute File.exists?(Store.files_dir("a_nope"))
  end

  test "a request with no file says so", %{conn: conn, id: id} do
    conn = post(conn, ~p"/api/agents/#{id}/files", %{})
    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "no files"
  end

  test "an oversized file is refused and the good ones are not left behind", %{
    conn: conn,
    id: id
  } do
    # All or nothing: a half-stored drop would leave the user guessing which of
    # the files the agent is about to see.
    conn =
      post(conn, ~p"/api/agents/#{id}/files", %{
        "files" => [
          upload("fine.txt", "ok"),
          upload("big.bin", String.duplicate("x", 26 * 1024 * 1024))
        ]
      })

    assert json_response(conn, 413)
    assert File.ls!(Store.files_dir(id)) == []
  end

  test "requires a token", %{id: id} do
    conn =
      build_conn()
      |> post(~p"/api/agents/#{id}/files", %{"files" => [upload("a.txt", "hi")]})

    assert json_response(conn, 401)
  end

  describe "reading an attachment back" do
    test "serves a file this session stored", %{conn: conn, id: id} do
      post(conn, ~p"/api/agents/#{id}/files", %{
        "files" => [upload("shot.png", "PNG", "image/png")]
      })

      conn = get(conn, "/api/agents/#{id}/files/shot.png")
      assert response(conn, 200) == "PNG"
    end

    test "anything outside the session's files is a 404", %{conn: conn, id: id} do
      File.mkdir_p!(Store.files_dir(id))
      File.write!(Path.join(Store.session_dir(id), "meta-ish.json"), "{}")

      for name <- ["missing.png", "..", "%2e%2e", "..%2fmeta-ish.json"] do
        assert json_response(get(conn, "/api/agents/#{id}/files/#{name}"), 404),
               "#{name} should not be served"
      end
    end

    test "an unknown session is a 404", %{conn: conn} do
      assert json_response(get(conn, "/api/agents/a_nobody/files/x.png"), 404)
    end

    test "requires a token", %{id: id} do
      assert json_response(get(build_conn(), "/api/agents/#{id}/files/x.png"), 401)
    end
  end
end
