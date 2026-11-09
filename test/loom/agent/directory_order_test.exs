defmodule Loom.Agent.DirectoryOrderTest do
  use ExUnit.Case, async: true

  alias Loom.Agent.DirectoryOrder

  setup do
    path =
      Path.join(System.tmp_dir!(), "loom-dirorder-#{System.unique_integer([:positive])}.json")

    name = :"dirorder_#{System.unique_integer([:positive])}"
    start_supervised!({DirectoryOrder, name: name, path: path})
    on_exit(fn -> File.rm(path) end)
    {:ok, server: name, path: path}
  end

  test "starts empty, keeps what is put, and survives a restart", %{server: s, path: path} do
    assert DirectoryOrder.list(s) == []
    assert :ok = DirectoryOrder.put([" 生活 ", "AWS Customers", "", "生活"], s)
    assert DirectoryOrder.list(s) == ["生活", "AWS Customers"]

    stop_supervised!(DirectoryOrder)
    start_supervised!({DirectoryOrder, name: :dirorder_again, path: path})
    assert DirectoryOrder.list(:dirorder_again) == ["生活", "AWS Customers"]
  end

  test "refuses what is not a path, keeping the order it had", %{server: s} do
    :ok = DirectoryOrder.put(["a"], s)
    assert {:error, :invalid_directory} = DirectoryOrder.put(["b", ".."], s)
    assert {:error, :invalid_directory} = DirectoryOrder.put(["b", 1], s)
    assert {:error, :invalid_directory} = DirectoryOrder.put("a", s)
    assert DirectoryOrder.list(s) == ["a"]
  end

  test "a rename keeps the place; a merge keeps the first", %{server: s} do
    :ok = DirectoryOrder.put(["a", "b", "c", "b/x"], s)
    :ok = DirectoryOrder.rebase("b", "z", s)
    assert DirectoryOrder.list(s) == ["a", "z", "c", "z/x"]
    :ok = DirectoryOrder.rebase("c", "a", s)
    assert DirectoryOrder.list(s) == ["a", "z", "z/x"]
  end

  test "a change is broadcast to the lobby, an unchanged put is not", %{server: s} do
    Phoenix.PubSub.subscribe(Loom.PubSub, Loom.Agent.lobby_topic())
    :ok = DirectoryOrder.put(["a", "b"], s)
    assert_receive {:directory_order, ["a", "b"]}
    :ok = DirectoryOrder.put(["a", "b"], s)
    refute_receive {:directory_order, _}, 50
  end
end
