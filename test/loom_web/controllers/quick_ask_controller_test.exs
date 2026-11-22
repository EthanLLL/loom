defmodule LoomWeb.QuickAskControllerTest do
  @moduledoc "Quick Ask: the setting, and a message that starts a session by it."
  # Not async: the stub has a fixed name and the backend map is global config.
  use LoomWeb.ConnCase, async: false

  alias Loom.Agent
  alias Loom.BackendStub

  setup %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "loom-qa-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:loom, Loom.Agent, [])

    Application.put_env(
      :loom,
      Loom.Agent,
      previous
      |> Keyword.put(:data_dir, Path.join(dir, "sessions"))
      |> Keyword.put(:backends, %{claude_code: BackendStub, codex: BackendStub, kiro: BackendStub})
    )

    Application.put_env(:loom, Loom.QuickAsk, path: Path.join(dir, "quick-ask.json"))
    start_supervised!({BackendStub, notify: self()})

    on_exit(fn ->
      for %{id: id} <- Agent.list_sessions(), do: Agent.stop_session(id)
      Process.sleep(50)
      Application.put_env(:loom, Loom.Agent, previous)
      Application.delete_env(:loom, Loom.QuickAsk)
      File.rm_rf(dir)
    end)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> Loom.Auth.mint_token())
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn}
  end

  test "Claude Code on Sonnet until it is set", %{conn: conn} do
    assert json_response(get(conn, ~p"/api/quick-ask/settings"), 200) ==
             %{"backend" => "claude_code", "model" => "sonnet"}
  end

  test "a set backend and model are what the next ask starts", %{conn: conn} do
    assert %{"backend" => "kiro", "model" => "small"} =
             conn
             |> put(~p"/api/quick-ask/settings", %{backend: "kiro", model: "small"})
             |> json_response(200)

    %{"id" => id} =
      conn |> post(~p"/api/quick-ask", %{text: "hi", device: "siri"}) |> json_response(201)

    assert BackendStub.await_turn() =~ "hi"
    assert %{backend: :kiro, model: "small"} = Agent.info(id)
  end

  test "an empty model is the backend's default", %{conn: conn} do
    assert %{"model" => nil} =
             conn
             |> put(~p"/api/quick-ask/settings", %{backend: "codex", model: ""})
             |> json_response(200)
  end

  test "refuses a backend or model that does not exist", %{conn: conn} do
    assert json_response(put(conn, ~p"/api/quick-ask/settings", %{backend: "gpt"}), 422)["error"] =~
             "backend"

    assert json_response(
             put(conn, ~p"/api/quick-ask/settings", %{backend: "kiro", model: "huge"}),
             422
           )["error"] =~ "huge"
  end

  test "an ask with a model the backend no longer lists starts nothing", %{conn: conn} do
    # The default, Sonnet, is not among the stub's models.
    assert json_response(post(conn, ~p"/api/quick-ask", %{text: "hi"}), 422)["error"] =~ "sonnet"
    assert Agent.list_sessions() == []
  end
end
