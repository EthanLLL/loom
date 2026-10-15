defmodule LoomWeb.LobbyChannelTest do
  @moduledoc """
  The sidebar's contract: the join reply is the whole list, and from then on
  every change to a session's header arrives as a push — no polling.
  """
  use LoomWeb.ChannelCase, async: false

  alias Loom.Agent
  alias Loom.BackendStub
  alias LoomWeb.LobbyChannel
  alias LoomWeb.UserSocket

  setup do
    data_dir = Path.join(System.tmp_dir!(), "loom-lobby-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:loom, Loom.Agent, [])

    Application.put_env(
      :loom,
      Loom.Agent,
      previous
      |> Keyword.put(:data_dir, data_dir)
      |> Keyword.put(:backends, %{claude_code: BackendStub, codex: BackendStub})
    )

    start_supervised!({BackendStub, notify: self()})

    id = "a_lobby_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Agent.start_session(id, backend: :claude_code)

    on_exit(fn ->
      for %{id: live} <- Agent.list_sessions(), do: Agent.stop_session(live)
      Process.sleep(50)
      Application.put_env(:loom, Loom.Agent, previous)
      File.rm_rf(data_dir)
    end)

    {:ok, id: id}
  end

  defp join_lobby do
    socket(UserSocket, nil, %{}) |> subscribe_and_join(LobbyChannel, "agents", %{})
  end

  test "the join reply is the whole session list", %{id: id} do
    assert {:ok, %{sessions: sessions}, _socket} = join_lobby()
    assert [%{id: ^id, status: :idle, seq: seq}] = sessions
    assert is_integer(seq)
  end

  test "a rename is pushed with a newer seq", %{id: id} do
    {:ok, %{sessions: [%{seq: before}]}, _socket} = join_lobby()

    :ok = Agent.rename(id, "Loom")

    assert_push "session", %{id: ^id, title: "Loom", seq: seq}
    assert seq > before
  end

  test "status changes through a turn are pushed", %{id: id} do
    {:ok, _reply, _socket} = join_lobby()

    {:ok, :started} = Agent.submit(id, "hello")
    BackendStub.await_turn()
    assert_push "session", %{id: ^id, status: :starting, title: "hello"}

    [{pid, _}] = Registry.lookup(Loom.Agent.Registry, id)
    send(pid, {:stub, [{:event, :turn_done, %{}}]})
    assert_push "session", %{id: ^id, status: :idle, turns: 1}
  end

  test "a new session is pushed, and a deleted one is removed" do
    {:ok, _reply, _socket} = join_lobby()

    other = "a_lobby_new_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Agent.start_session(other, backend: :claude_code)
    assert_push "session", %{id: ^other}

    Agent.delete_session(other)
    assert_push "removed", %{id: ^other}
  end
end
