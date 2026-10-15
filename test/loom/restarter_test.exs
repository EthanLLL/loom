defmodule Loom.RestarterTest do
  @moduledoc """
  The restart waits for every turn, and never forces one: it stops the node
  only once nothing is running, and gives up rather than cut a turn short.
  """
  use ExUnit.Case, async: false

  alias Loom.Agent
  alias Loom.BackendStub
  alias Loom.Restarter

  setup do
    data_dir = Path.join(System.tmp_dir!(), "loom-restart-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:loom, Loom.Agent, [])

    Application.put_env(
      :loom,
      Loom.Agent,
      previous
      |> Keyword.put(:data_dir, data_dir)
      |> Keyword.put(:backends, %{claude_code: BackendStub, codex: BackendStub})
    )

    start_supervised!({BackendStub, notify: self()})

    test_pid = self()

    restarter =
      start_supervised!(
        {Restarter,
         name: :"restarter_#{System.unique_integer([:positive])}",
         stop: fn -> send(test_pid, :stopped) end,
         settle_ms: 20}
      )

    id = "a_restart_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Agent.start_session(id, backend: :claude_code)

    on_exit(fn ->
      for %{id: live} <- Agent.list_sessions(), do: Agent.stop_session(live)
      Process.sleep(50)
      Application.put_env(:loom, Loom.Agent, previous)
      File.rm_rf(data_dir)
    end)

    {:ok, id: id, server: restarter}
  end

  defp start_turn(id) do
    {:ok, :started} = Agent.submit(id, "work")
    BackendStub.await_turn()
  end

  defp finish_turn(id) do
    [{pid, _}] = Registry.lookup(Loom.Agent.Registry, id)
    send(pid, {:stub, [{:event, :turn_done, %{}}]})
  end

  test "with every session idle it stops right away", %{server: server} do
    assert {:ok, :pending, []} = Restarter.request(server: server)
    assert_receive :stopped, 500
    assert Restarter.status(server) == :idle
  end

  test "it waits for a running turn to finish", %{id: id, server: server} do
    start_turn(id)

    assert {:ok, :pending, [^id]} = Restarter.request(server: server)
    refute_receive :stopped, 100

    finish_turn(id)
    assert_receive :stopped, 500
  end

  test "a second request while one is pending is a no-op", %{id: id, server: server} do
    start_turn(id)
    {:ok, :pending, _} = Restarter.request(server: server)
    assert {:ok, :already_pending} = Restarter.request(server: server)
  end

  test "a cancelled request never stops", %{id: id, server: server} do
    start_turn(id)
    {:ok, :pending, _} = Restarter.request(server: server)
    :ok = Restarter.cancel(server)

    finish_turn(id)
    refute_receive :stopped, 200
    assert Restarter.status(server) == :idle
  end

  test "it gives up instead of forcing a restart", %{id: id, server: server} do
    start_turn(id)
    {:ok, :pending, _} = Restarter.request(server: server, timeout_ms: 50)

    refute_receive :stopped, 200
    assert Restarter.status(server) == :idle

    # Expired means expired: the turn finishing later does not revive it.
    finish_turn(id)
    refute_receive :stopped, 200
  end
end
