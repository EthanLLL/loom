defmodule Loom.Agent.Codex.ServerTest do
  @moduledoc """
  The degraded path: what happens to callers when there is no app-server.

  This is the state a machine without `codex` installed boots into, and the one
  every session passes through while the server is being respawned. It has to be
  a clear answer rather than a timeout — a 60-second hang with no explanation is
  how a background agent comes to look broken.
  """
  use ExUnit.Case, async: false

  alias Loom.Agent.Codex.Server

  # The application already runs the server; under test it is configured with
  # `spawn: false` (`config/test.exs`), so no real app-server exists. That is
  # exactly the degraded state these tests are about.
  setup do
    {:ok, server: Process.whereis(Server)}
  end

  test "it is part of the application, not started on demand", %{server: pid} do
    assert is_pid(pid), "Codex.Server should be running for the whole node"
  end

  test "reports itself unavailable rather than pretending" do
    refute Server.available?()
  end

  test "every call is refused immediately, not left to time out" do
    assert Server.start_thread(cwd: "/tmp") == {:error, :server_down}
    assert Server.resume_thread("some-thread") == {:error, :server_down}
    assert Server.start_turn("some-thread", "hello") == {:error, :server_down}
    assert Server.interrupt("some-thread", "some-turn") == {:error, :server_down}
  end

  test "releasing a thread is still safe with no server" do
    # Teardown runs on paths where the server may already be gone; it must not
    # crash the session that is shutting down.
    assert Server.release("some-thread") == :ok
  end

  test "the backend turns server_down into something a user can read" do
    assert {:error, reason} = Loom.Agent.Backend.Codex.start("a_1", %{})
    assert reason == "the codex app-server stopped"
  end

  test "it stays alive while unavailable", %{server: pid} do
    # The whole reason respawning happens inside the process: a crash-looping
    # child would take the application down with it.
    assert Server.start_thread(cwd: "/tmp") == {:error, :server_down}
    Process.sleep(50)
    assert Process.alive?(pid)
  end
end
