defmodule LoomWeb.NodeTest do
  @moduledoc """
  A device end to end, with the test process standing in for `loom-node
  daemon`: registering and installing it, the CLI's routes relaying through its
  channel, and what the CLI sees when the device goes away mid-request.
  """
  # Not async: `Loom.Nodes` is the application's one registry.
  use LoomWeb.ChannelCase, async: false

  import Plug.Conn, only: [put_req_header: 3]
  import Phoenix.ConnTest, except: [connect: 2, connect: 3]

  alias Loom.Nodes
  alias LoomWeb.NodeSocket

  setup do
    on_exit(fn -> for %{id: id} <- Nodes.list(), do: Nodes.delete(id) end)
    :ok
  end

  defp register(name \\ "dev#{System.unique_integer([:positive])}") do
    {:ok, node, code} = Nodes.create(name)
    {:ok, _node, token} = Nodes.redeem(code)
    {node, token}
  end

  defp online do
    {node, token} = register()
    {:ok, socket} = connect(NodeSocket, %{"token" => token})
    {:ok, _reply, socket} = subscribe_and_join(socket, "node", %{"os" => "darwin"})
    {node, socket}
  end

  defp cli(conn \\ build_conn()), do: put_req_header(conn, "x-loom-key", Nodes.cli_key())

  defp events(conn) do
    conn.resp_body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  describe "registering" do
    test "an install code is good once, and mints the token" do
      {:ok, node, code} = Nodes.create("mac")
      refute node.online

      assert {:ok, _node, "ln_" <> _ = token} = Nodes.redeem(code)
      assert {:ok, id} = Nodes.authenticate(token)
      assert id == node.id
      assert {:error, :invalid_code} = Nodes.redeem(code)
    end

    test "reinstalling replaces the token" do
      {node, old} = register()
      {:ok, code} = Nodes.install_code(node.id)
      {:ok, _node, new} = Nodes.redeem(code)

      assert :error = Nodes.authenticate(old)
      assert {:ok, _} = Nodes.authenticate(new)
    end

    test "names are checked and unique regardless of case" do
      {:ok, _node, _code} = Nodes.create("Mac")
      assert {:error, _} = Nodes.create("mac")
      assert {:error, _} = Nodes.create("has space")
      assert {:error, _} = Nodes.create("")

      {:ok, other, _} = Nodes.create("wsl")
      assert {:error, _} = Nodes.rename(other.id, "MAC")
      assert {:ok, %{name: "box"}} = Nodes.rename(other.id, "box")
    end

    test "a removed device's token is refused at connect" do
      {node, token} = register()
      :ok = Nodes.delete(node.id)
      assert :error = connect(NodeSocket, %{"token" => token})
    end

    test "the install script carries a fresh token and works once" do
      {:ok, _node, code} = Nodes.create("box#{System.unique_integer([:positive])}")

      conn =
        build_conn()
        |> put_req_header("x-forwarded-proto", "https")
        |> Map.put(:host, "loom.example")
        |> get("/node/install/#{code}")

      assert conn.status == 200
      assert conn.resp_body =~ "URL='https://loom.example'"
      [_, token] = Regex.run(~r/TOKEN='([^']+)'/, conn.resp_body)
      assert {:ok, _} = Nodes.authenticate(token)

      assert get(build_conn(), "/node/install/#{code}").status == 404
    end
  end

  describe "presence" do
    test "joining and leaving are pushed to the lobby" do
      Phoenix.PubSub.subscribe(Loom.PubSub, Loom.Agent.lobby_topic())
      {node, socket} = online()
      id = node.id

      assert_receive {:node_summary, %{id: ^id, online: true, os: "darwin"}}
      Process.unlink(socket.channel_pid)
      Process.exit(socket.channel_pid, :kill)
      assert_receive {:node_summary, %{id: ^id, online: false}}
    end

    test "a newer connection from the same device replaces the old one" do
      {node, token} = register()
      {:ok, socket} = connect(NodeSocket, %{"token" => token})
      {:ok, _, first} = subscribe_and_join(socket, "node", %{})
      Process.unlink(first.channel_pid)
      ref = Process.monitor(first.channel_pid)

      {:ok, socket} = connect(NodeSocket, %{"token" => token})
      {:ok, _, _second} = subscribe_and_join(socket, "node", %{})

      assert_receive {:DOWN, ^ref, _, _, _}
      assert [%{online: true}] = Enum.filter(Nodes.list(), &(&1.id == node.id))
    end
  end

  describe "the CLI's routes" do
    test "are refused without the key, and through Cloudflare even with it" do
      assert get(build_conn(), "/api/node/list").status == 403

      assert get(put_req_header(build_conn(), "x-loom-key", "nope"), "/api/node/list").status ==
               403

      assert get(cli() |> put_req_header("cf-ray", "abc"), "/api/node/list").status == 403
      assert get(cli(), "/api/node/list").status == 200
    end

    test "exec streams the device's output and exit" do
      {node, socket} = online()

      task =
        Task.async(fn ->
          post(cli(), "/api/node/exec", %{"node" => node.name, "cmd" => "echo hi", "timeout" => 5})
        end)

      assert_push "exec", %{"id" => id, "cmd" => "echo hi", "timeout" => 5}
      push(socket, "out", %{"id" => id, "stream" => "stdout", "data" => Base.encode64("hi\n")})
      push(socket, "exit", %{"id" => id, "code" => 3, "timed_out" => false})

      conn = Task.await(task)
      assert [out, exit] = events(conn) |> Enum.reject(&(&1["t"] == "ping"))
      assert out == %{"t" => "out", "stream" => "stdout", "data" => Base.encode64("hi\n")}
      assert %{"t" => "exit", "code" => 3} = exit
    end

    test "a device lost mid-command ends the stream with lost" do
      {node, socket} = online()
      Process.unlink(socket.channel_pid)

      task =
        Task.async(fn ->
          post(cli(), "/api/node/exec", %{"node" => node.name, "cmd" => "sleep 9"})
        end)

      assert_push "exec", %{"id" => _}
      Process.exit(socket.channel_pid, :kill)

      assert [%{"t" => "error", "lost" => true}] =
               Task.await(task) |> events() |> Enum.reject(&(&1["t"] == "ping"))
    end

    test "an interrupted CLI cancels the command on the device" do
      {node, _socket} = online()

      {:ok, pid} =
        Task.start(fn ->
          post(cli(), "/api/node/exec", %{"node" => node.name, "cmd" => "sleep 9"})
        end)

      assert_push "exec", %{"id" => id}
      Process.exit(pid, :kill)
      assert_push "cancel", %{"id" => ^id}
    end

    test "an offline device is a 503 after the wait, an unknown one a 404" do
      {node, _token} = register()

      conn = post(cli(), "/api/node/exec", %{"node" => node.name, "cmd" => "true"})
      assert conn.status == 503
      assert json_response(conn, 503)["error"] =~ "offline"

      conn = post(cli(), "/api/node/exec", %{"node" => "nowhere", "cmd" => "true"})
      assert json_response(conn, 404)["error"] =~ node.name
    end

    test "read relays chunks until done" do
      {node, socket} = online()

      task =
        Task.async(fn ->
          get(cli(), "/api/node/read", %{"node" => node.name, "path" => "~/a"})
        end)

      assert_push "read", %{"id" => id, "path" => "~/a"}
      push(socket, "chunk", %{"id" => id, "data" => Base.encode64("abc")})
      push(socket, "done", %{"id" => id, "size" => 3})

      assert [%{"t" => "chunk"}, %{"t" => "done", "size" => 3}] =
               Task.await(task) |> events() |> Enum.reject(&(&1["t"] == "ping"))
    end

    test "write sends the body and answers with the device's confirmation" do
      {node, socket} = online()

      task =
        Task.async(fn ->
          cli()
          |> put_req_header("content-type", "application/octet-stream")
          |> post("/api/node/write?node=#{node.name}&path=/tmp/x", "payload")
        end)

      assert_push "write", %{"id" => id, "path" => "/tmp/x", "data" => data, "final" => true}
      assert Base.decode64!(data) == "payload"
      push(socket, "written", %{"id" => id, "size" => 7})

      assert %{"size" => 7} = Task.await(task) |> json_response(200)
    end
  end
end
