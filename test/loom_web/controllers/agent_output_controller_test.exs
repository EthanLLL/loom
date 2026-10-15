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
end
