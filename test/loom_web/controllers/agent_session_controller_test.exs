defmodule LoomWeb.AgentSessionControllerTest do
  @moduledoc """
  The HTTP surface the browser creates sessions through.

  Creation is the only place the backend is chosen, and the choice is permanent,
  so "it refuses to guess" is the behaviour worth pinning down.
  """
  # Not async: the stub has a fixed name and the backend map is global config.
  use LoomWeb.ConnCase, async: false

  alias Loom.Agent
  alias Loom.BackendStub

  setup %{conn: conn} do
    data_dir = Path.join(System.tmp_dir!(), "loom-ctl-#{System.unique_integer([:positive])}")
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

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> Loom.Auth.mint_token())
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn}
  end

  describe "POST /api/agents" do
    test "creates a session bound to the requested backend", %{conn: conn} do
      conn = post(conn, ~p"/api/agents", %{backend: "claude_code"})

      assert %{"id" => id, "backend" => "claude_code", "status" => "idle"} =
               json_response(conn, 201)

      assert Agent.exists?(id)
    end

    test "codex works the same way", %{conn: conn} do
      conn = post(conn, ~p"/api/agents", %{backend: "codex"})
      assert %{"backend" => "codex"} = json_response(conn, 201)
    end

    test "refuses to pick a backend when none is given", %{conn: conn} do
      # Permanent binding: a wrong guess would commit the user to the wrong
      # engine with no way to migrate the conversation.
      conn = post(conn, ~p"/api/agents", %{})
      assert %{"error" => error} = json_response(conn, 422)
      assert error =~ "claude_code"
      assert Agent.list_sessions() == []
    end

    test "refuses an unknown backend and says what was given", %{conn: conn} do
      conn = post(conn, ~p"/api/agents", %{backend: "gpt"})
      assert %{"given" => "gpt"} = json_response(conn, 422)
    end

    test "the response carries everything the sidebar renders", %{conn: conn} do
      conn = post(conn, ~p"/api/agents", %{backend: "codex", title: "a title"})
      body = json_response(conn, 201)

      for key <- ~w(id title backend backend_label created_at status queued queue
                    context_tokens context_window turns) do
        assert Map.has_key?(body, key), "missing #{key}"
      end

      assert body["backend_label"] == "Codex"
    end

    test "requires a token", %{conn: conn} do
      conn = conn |> delete_req_header("authorization") |> post(~p"/api/agents", %{})
      assert json_response(conn, 401)
    end
  end

  describe "PATCH /api/agents/:id" do
    test "renames without touching the backend", %{conn: conn} do
      %{"id" => id} = post(conn, ~p"/api/agents", %{backend: "codex"}) |> json_response(201)

      conn = patch(conn, ~p"/api/agents/#{id}", %{title: "the good branch"})
      assert %{"title" => "the good branch"} = json_response(conn, 200)

      # A title is a sidebar label, not conversation state.
      BackendStub.refute_turn()
    end

    test "an empty title is refused", %{conn: conn} do
      %{"id" => id} = post(conn, ~p"/api/agents", %{backend: "codex"}) |> json_response(201)

      conn = patch(conn, ~p"/api/agents/#{id}", %{title: "   "})
      assert json_response(conn, 422)
    end
  end

  describe "directories" do
    test "PATCH with a directory files the session there, and it survives a restore", %{
      conn: conn
    } do
      %{"id" => id} = post(conn, ~p"/api/agents", %{backend: "codex"}) |> json_response(201)

      conn = patch(conn, ~p"/api/agents/#{id}", %{directory: " work / aws "})
      assert %{"directory" => "work/aws"} = json_response(conn, 200)

      Agent.stop_session(id)
      {:ok, _pid} = Agent.restore_session(id)
      assert %{directory: "work/aws"} = Agent.info(id)
    end

    test "a bad directory is refused", %{conn: conn} do
      %{"id" => id} = post(conn, ~p"/api/agents", %{backend: "codex"}) |> json_response(201)
      assert conn |> patch(~p"/api/agents/#{id}", %{directory: "a/../b"}) |> json_response(422)
    end

    test "moving a directory takes everything under it, and only that", %{conn: conn} do
      ids =
        for dir <- ["work", "work/aws", "workshop", ""] do
          %{"id" => id} = post(conn, ~p"/api/agents", %{backend: "codex"}) |> json_response(201)
          :ok = Agent.move(id, dir)
          id
        end

      assert conn
             |> post(~p"/api/directories/move", %{from: "work", to: "job/2026"})
             |> response(204)

      assert Enum.map(ids, &Agent.info(&1).directory) == [
               "job/2026",
               "job/2026/aws",
               "workshop",
               ""
             ]
    end

    test "a directory cannot go inside itself, and the root does not move", %{conn: conn} do
      assert conn
             |> post(~p"/api/directories/move", %{from: "a", to: "a/b"})
             |> json_response(422)

      assert conn |> post(~p"/api/directories/move", %{from: "", to: "b"}) |> json_response(422)
    end
  end

  describe "GET /api/agents" do
    test "lists live sessions with their backends", %{conn: conn} do
      post(conn, ~p"/api/agents", %{backend: "claude_code"})
      post(conn, ~p"/api/agents", %{backend: "codex"})

      assert %{"sessions" => sessions} = get(conn, ~p"/api/agents") |> json_response(200)
      assert Enum.sort(Enum.map(sessions, & &1["backend"])) == ["claude_code", "codex"]
    end
  end

  describe "DELETE /api/agents/:id" do
    test "stops the session and discards its history", %{conn: conn} do
      %{"id" => id} =
        post(conn, ~p"/api/agents", %{backend: "claude_code"}) |> json_response(201)

      assert conn |> delete(~p"/api/agents/#{id}") |> response(204)
      refute Agent.exists?(id)
      assert Agent.list_persisted() == []
    end
  end
end
