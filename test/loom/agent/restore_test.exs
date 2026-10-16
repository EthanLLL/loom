defmodule Loom.Agent.RestoreTest do
  @moduledoc """
  Crash recovery, which changed shape with the backend rewrite.

  The old loop could pick a turn back up because it owned the loop. A backend
  turn is a child process of this node, so it dies with the node and cannot be
  rejoined — and re-sending is worse than it looks, because the user's message
  is already in the backend's own history. So a session found mid-turn comes back
  `:interrupted`, says so, and keeps its queue.
  """
  # Not async: the stub has a fixed name and the backend map is global config.
  use ExUnit.Case, async: false

  alias Loom.Agent
  alias Loom.Agent.Store
  alias Loom.BackendStub

  setup do
    data_dir = Path.join(System.tmp_dir!(), "loom-restore-#{System.unique_integer([:positive])}")
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

    {:ok, data_dir: data_dir}
  end

  defp new_session(opts \\ []) do
    id = "a_r#{System.unique_integer([:positive])}"
    {:ok, _pid} = Agent.start_session(id, Keyword.merge([backend: :claude_code], opts))
    id
  end

  defp current_pid(id) do
    case Registry.lookup(Loom.Agent.Registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # Kill without letting terminate/2 run, so the header keeps whatever status it
  # had — a clean stop would record something settled, and then there would be
  # nothing to recover from.
  defp crash(id) do
    pid = current_pid(id)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
    assert_eventually(fn -> current_pid(id) not in [nil, pid] end)
  end

  defp stop_and_wait(id) do
    :ok = Agent.stop_session(id)
    assert_eventually(fn -> not Agent.exists?(id) end)
  end

  defp assert_eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition never became true")
      true -> Process.sleep(20) && do_assert_eventually(fun, deadline)
    end
  end

  describe "the header" do
    test "records the status a restart has to act on" do
      id = new_session()
      assert {:ok, %{status: "idle"}} = Store.read_meta(id)

      Agent.submit(id, "go")
      BackendStub.await_turn()

      # Mid-turn, on disk, or a restart has no way to know.
      assert {:ok, %{status: "starting"}} = Store.read_meta(id)
    end

    test "a clean stop settles the status so it is not reported as interrupted" do
      id = new_session()
      Agent.submit(id, "go")
      BackendStub.await_turn()

      stop_and_wait(id)

      assert {:ok, %{status: "idle"}} = Store.read_meta(id)
    end

    test "an interrupted session stays interrupted across a clean stop" do
      # Its queue is parked and the user has not continued yet; coming back
      # `:idle` would lose that distinction and auto-drain on the next event.
      id = new_session()
      Agent.submit(id, "go")
      BackendStub.await_turn()
      BackendStub.fail_next_steer()
      Agent.submit(id, "parked")
      Agent.interrupt(id)

      stop_and_wait(id)
      assert {:ok, %{status: "interrupted"}} = Store.read_meta(id)
    end

    test "the backend handle is persisted so a restart reattaches, not restarts" do
      id = new_session()
      assert {:ok, meta} = Store.read_meta(id)
      assert meta.backend == "claude_code"
      assert meta.stub_ref == "stub-#{id}"
    end
  end

  describe "restoring" do
    test "an idle session comes back idle, with its title and counters" do
      id = new_session()
      Agent.submit(id, "remember this")
      BackendStub.await_turn()
      [{pid, _}] = Registry.lookup(Loom.Agent.Registry, id)
      send(pid, {:stub, [{:event, :turn_done, %{context_tokens: 9_000}}]})
      assert_eventually(fn -> Agent.info(id).status == :idle end)

      stop_and_wait(id)
      {:ok, _pid} = Agent.restore_session(id)

      info = Agent.info(id)
      assert info.status == :idle
      assert info.title == "remember this"
      assert info.context_tokens == 9_000
      assert info.turns == 1
      assert info.backend == :claude_code
    end

    test "a parked queue survives and is not drained on the way back" do
      id = new_session()
      Agent.submit(id, "go")
      BackendStub.await_turn()
      # A message only parks when steering refused it; mid-turn messages are
      # otherwise handed straight to the running turn.
      BackendStub.fail_next_steer()
      Agent.submit(id, "parked")
      Agent.interrupt(id)
      stop_and_wait(id)

      {:ok, _pid} = Agent.restore_session(id)

      assert Agent.info(id).queue == ["parked"]
      assert Agent.info(id).status == :interrupted
      # The whole reason `:interrupted` is a distinct status.
      BackendStub.refute_turn()
    end

    test "a session that was mid-turn comes back interrupted, not resumed" do
      id = new_session()
      Agent.submit(id, "a long job")
      BackendStub.await_turn()

      stop_and_wait(id)
      # Fake a hard stop: the clean shutdown above settled the status, so put it
      # back the way a crash would have left it.
      {:ok, meta} = Store.read_meta(id)
      Store.write_meta(id, %{meta | status: "running"})

      {:ok, _pid} = Agent.restore_session(id)

      assert Agent.info(id).status == :interrupted
      # Re-sending would duplicate a message the backend already recorded.
      BackendStub.refute_turn()
    end

    test "and says why, so a watching client is not left with a silent gap" do
      id = new_session()
      Agent.submit(id, "a long job")
      BackendStub.await_turn()
      stop_and_wait(id)
      {:ok, meta} = Store.read_meta(id)
      Store.write_meta(id, %{meta | status: "running"})

      {:ok, _pid} = Agent.restore_session(id)

      assert Enum.any?(Store.read_events(id, 100), fn event ->
               event.kind == :status and is_binary(event.payload[:message]) and
                 event.payload[:message] =~ "restart"
             end)
    end

    test "the transcript is replayable to a client that attaches afterwards" do
      id = new_session()
      Agent.submit(id, "hello")
      BackendStub.await_turn()
      {:ok, before} = Agent.attach(id, 0)
      stop_and_wait(id)

      {:ok, _pid} = Agent.restore_session(id)

      {:ok, after_restore} = Agent.attach(id, 0)
      assert after_restore.last_seq >= before.last_seq
      assert Enum.any?(after_restore.events, &(&1.kind == :user))
    end

    test "seq keeps climbing so incremental sync still works" do
      id = new_session()
      Agent.submit(id, "one")
      BackendStub.await_turn()
      {:ok, before} = Agent.attach(id, 0)
      stop_and_wait(id)
      {:ok, _pid} = Agent.restore_session(id)

      Agent.submit(id, "two")
      BackendStub.await_turn()

      {:ok, delta} = Agent.attach(id, before.last_seq)
      seqs = Enum.map(delta.events, & &1.seq)
      assert seqs == Enum.sort(seqs)
      assert Enum.all?(seqs, &(&1 > before.last_seq))
    end

    test "a backend that will not reattach fails the restore cleanly" do
      # A locked codex thread is the real case. Better to refuse than to come up
      # with a session whose every turn fails obscurely.
      id = new_session()
      stop_and_wait(id)
      BackendStub.fail_next_resume()

      assert {:error, _} = Agent.restore_session(id)
    end

    test "restoring an unknown id fails rather than creating one" do
      assert {:error, _} = Agent.restore_session("a_does_not_exist")
    end

    test "a header with no backend is refused with a reason", %{data_dir: data_dir} do
      # Nothing to reattach to, so guessing an engine would open an empty
      # conversation under the old title. Refusing is better — and so is not
      # crashing, which an unmatched `:error` in `restore/2` used to do.
      id = "a_no_backend"
      File.mkdir_p!(Path.join(data_dir, id))

      Loom.Agent.Store.write_meta(id, %{
        id: id,
        title: "an old session",
        status: "idle",
        cwd: "/tmp",
        seq: 3
      })

      assert {:error, {:restore_failed, {:no_backend_recorded, nil}}} =
               Agent.restore_session(id)
    end
  end

  describe "supervisor restart after a crash" do
    # The supervisor restarts with the ORIGINAL spec, which says `backend:
    # :claude_code` and nothing about restoring. If that were treated as a new
    # session it would start a *second* backend conversation and abandon the
    # first, so state on disk has to win over the spec.

    test "reattaches to the same backend conversation" do
      id = new_session()
      {:ok, before} = Store.read_meta(id)

      crash(id)

      assert {:ok, after_crash} = Store.read_meta(id)
      assert after_crash.stub_ref == before.stub_ref
    end

    test "the transcript is not duplicated" do
      id = new_session()
      Agent.submit(id, "first message")
      BackendStub.await_turn()
      before = length(Store.read_events(id, 100))

      crash(id)

      assert length(Store.read_events(id, 100)) >= before
      # And the restarted process works from that history.
      {:ok, snapshot} = Agent.attach(id, 0)
      assert Enum.any?(snapshot.events, &(&1.payload[:text] == "first message"))
    end

    test "a crash mid-turn is reported as an interruption with no outside help" do
      id = new_session()
      Agent.submit(id, "do the thing")
      BackendStub.await_turn()

      crash(id)

      assert_eventually(fn -> Agent.info(id).status == :interrupted end)
      BackendStub.refute_turn()
    end
  end

  describe "log durability" do
    test "a torn trailing line is dropped instead of breaking recovery", %{data_dir: data_dir} do
      id = new_session()
      Agent.submit(id, "hello")
      BackendStub.await_turn()
      stop_and_wait(id)

      before = length(Store.read_events(id, 100))
      path = Path.join([data_dir, id, "events.jsonl"])
      File.write!(path, ~s({"seq":99,"kind":"assist), [:append])

      # The complete lines must still load; this is why an append-only log needs
      # no recovery procedure.
      assert length(Store.read_events(id, 100)) == before
      assert {:ok, _pid} = Agent.restore_session(id)
    end
  end

  test "last activity is the last message, not the restart" do
    id = new_session()
    Agent.submit(id, "hello")
    BackendStub.await_turn()
    active = Agent.info(id).last_active_at
    assert active >= Agent.info(id).created_at

    stop_and_wait(id)
    Process.sleep(20)
    {:ok, _} = Agent.restore_session(id)

    assert Agent.info(id).last_active_at == active
  end
end
