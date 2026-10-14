defmodule Loom.Agent.SessionTest do
  @moduledoc """
  What the session owns now that the backend owns the agent loop: the queue, the
  status it implies, the transcript, and the header that survives a restart.

  The rules under test are the ones in `docs/architecture.md` §2.2, and
  the one that is easy to get wrong is the asymmetry: a turn ending drains the
  queue, an interrupt does not.
  """
  # Not async: the stub has a fixed name and the backend map is global config.
  use ExUnit.Case, async: false

  alias Loom.Agent
  alias Loom.Agent.Store
  alias Loom.BackendStub

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "loom-session-#{System.unique_integer([:positive])}")

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
    id = "a_s#{System.unique_integer([:positive])}"
    {:ok, _pid} = Agent.start_session(id, Keyword.merge([backend: :claude_code], opts))
    id
  end

  # Drive the backend's output directly; the session forwards it to the stub's
  # decode/2, which hands it back unchanged.
  defp backend_sends(id, out) do
    [{pid, _}] = Registry.lookup(Loom.Agent.Registry, id)
    send(pid, {:stub, out})
    # Round-trip a call so the message is processed before the test continues.
    _ = Agent.info(id)
    :ok
  end

  defp assert_eventually(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      if fun.(), do: :ok, else: Process.sleep(20)
    end)
    |> Enum.find(fn result ->
      result == :ok or System.monotonic_time(:millisecond) > deadline
    end)
    |> case do
      :ok -> :ok
      _ -> flunk("condition never became true")
    end
  end

  defp finish_turn(id, payload \\ %{}) do
    backend_sends(id, [{:event, :turn_done, payload}])
  end

  describe "starting a session" do
    test "requires a backend and will not pick one" do
      # The binding is permanent — the conversation lives in that engine's own
      # store — so a wrong guess is unrecoverable.
      assert {:error, {:backend_required, nil}} = Agent.start_session("a_nope", [])

      assert {:error, {:backend_required, "bogus"}} =
               Agent.start_session("a_nope", backend: "bogus")
    end

    test "records the backend in the header so a restart reattaches to the right one" do
      id = new_session()
      assert {:ok, meta} = Store.read_meta(id)
      assert meta.backend == "claude_code"
      assert meta.stub_ref == "stub-#{id}"
    end

    test "starts idle, with nothing sent to the backend" do
      id = new_session()
      assert Agent.info(id).status == :idle
      BackendStub.refute_turn()
    end
  end

  describe "submitting" do
    test "an idle session starts a turn immediately" do
      id = new_session()

      assert {:ok, :started} = Agent.submit(id, "do the thing")
      assert BackendStub.await_turn() == "do the thing"
      assert Agent.info(id).status == :starting
    end

    test "the session is named after its first message" do
      id = new_session()
      Agent.submit(id, "fix the login bug\nand also the logout one")
      assert Agent.info(id).title == "fix the login bug"
    end

    test "an empty message is refused" do
      id = new_session()
      assert {:error, :empty} = Agent.submit(id, "   ")
      BackendStub.refute_turn()
    end

    test "a message sent mid-turn joins that turn instead of waiting" do
      # Both backends inject it into the running turn (measured). Queuing it
      # would throw away the one thing that makes typing mid-turn useful: the
      # instruction landing before the work is finished.
      id = new_session()
      Agent.submit(id, "first")
      BackendStub.await_turn()

      assert {:ok, :steered} = Agent.submit(id, "actually, not like that")

      assert BackendStub.await_steer() == "actually, not like that"
      # Not a new turn, and nothing parked.
      BackendStub.refute_turn()
      assert Agent.info(id).queued == 0
    end

    test "a refused steer falls back to the queue rather than being lost" do
      # Codex refuses when the turn ended between us deciding to steer and the
      # call landing. Late beats lost.
      id = new_session()
      Agent.submit(id, "first")
      BackendStub.await_turn()
      BackendStub.fail_next_steer()

      assert {:ok, :queued} = Agent.submit(id, "second")
      assert Agent.info(id).queue == ["second"]

      finish_turn(id)
      assert BackendStub.await_turn() == "second"
    end

    test "a turn ending with an empty queue goes idle" do
      id = new_session()
      Agent.submit(id, "hello")
      BackendStub.await_turn()
      finish_turn(id)

      assert Agent.info(id).status == :idle
      BackendStub.refute_turn()
    end

    test "a backend that refuses to start reports it and stays idle" do
      id = new_session()
      Phoenix.PubSub.subscribe(Loom.PubSub, Agent.topic(id))
      BackendStub.fail_next_turn()

      Agent.submit(id, "go")

      assert_receive {:agent_event, ^id, %{kind: :error, payload: %{message: message}}}, 500
      assert message =~ "stub refused"
      assert Agent.info(id).status == :idle

      # The message must not be lost: dropping it because the backend hiccuped
      # throws away work the user cannot get back.
      assert Agent.info(id).queue == ["go"]
    end

    test "a message kept after a failed start goes out with the next one" do
      id = new_session()
      BackendStub.fail_next_turn()
      Agent.submit(id, "first attempt")
      # The stub reports the attempt before refusing it; consume that so the
      # assertion below sees the retry and not the failure.
      assert BackendStub.await_turn() == "first attempt"
      assert_eventually(fn -> Agent.info(id).status == :idle end)

      assert {:ok, :started} = Agent.submit(id, "try again")
      assert BackendStub.await_turn() == "first attempt\n\ntry again"
    end
  end

  describe "interrupting" do
    setup do
      id = new_session()
      Phoenix.PubSub.subscribe(Loom.PubSub, Agent.topic(id))
      Agent.submit(id, "a long job")
      BackendStub.await_turn()
      {:ok, id: id}
    end

    test "stops the turn and starts nothing else", %{id: id} do
      assert :ok = Agent.interrupt(id)
      assert_receive :stub_interrupt, 500

      assert Agent.info(id).status == :interrupted
      # Stopping the agent must not immediately start something else.
      BackendStub.refute_turn()
    end

    test "anything already parked stays parked, it is not sent on the way out", %{id: id} do
      # A message only ends up parked when steering refused it. Stopping the
      # agent must not then quietly deliver it.
      BackendStub.fail_next_steer()
      Agent.submit(id, "parked")
      assert Agent.info(id).queued == 1

      Agent.interrupt(id)

      assert Agent.info(id).queued == 1
      BackendStub.refute_turn()
      BackendStub.refute_steer()
    end

    test "typing is how a stopped session continues, and it carries the parked", %{id: id} do
      BackendStub.fail_next_steer()
      Agent.submit(id, "parked")
      Agent.interrupt(id)

      assert {:ok, :started} = Agent.submit(id, "actually, do this instead")

      # No resume button, no continue/discard prompt: one code path.
      assert BackendStub.await_turn() == "parked\n\nactually, do this instead"
      assert Agent.info(id).queued == 0
    end

    test "tells clients why it stopped", %{id: id} do
      Agent.interrupt(id)

      assert_receive {:agent_event, ^id,
                      %{kind: :status, payload: %{status: :interrupted, message: message}}},
                     500

      assert message =~ "interrupted"
    end

    test "interrupting an idle session is a no-op", %{id: id} do
      finish_turn(id)
      assert Agent.info(id).status == :idle
      assert Agent.interrupt(id) == :ok
      refute_receive :stub_interrupt, 100
    end

    test "a parked message can be dropped so a stale one need not be sent", %{id: id} do
      # They were written for a trajectory that no longer exists.
      BackendStub.fail_next_steer()
      Agent.submit(id, "stale")
      BackendStub.fail_next_steer()
      Agent.submit(id, "also stale")
      Agent.interrupt(id)

      assert :ok = Agent.drop_queued(id, 0)
      assert Agent.info(id).queue == ["also stale"]

      assert {:error, :out_of_range} = Agent.drop_queued(id, 5)
    end
  end

  describe "renaming" do
    test "changes the title locally and tells clients" do
      id = new_session()
      Phoenix.PubSub.subscribe(Loom.PubSub, Agent.topic(id))

      assert :ok = Agent.rename(id, "the good branch")

      assert_receive {:agent_event, ^id, %{kind: :renamed, payload: %{title: "the good branch"}}},
                     500

      assert Agent.info(id).title == "the good branch"
      assert {:ok, %{title: "the good branch"}} = Store.read_meta(id)
      # Never pushed to the backend: a title is a sidebar label, not
      # conversation state.
      BackendStub.refute_turn()
    end

    test "an empty title is refused" do
      id = new_session()
      assert {:error, :empty} = Agent.rename(id, "  ")
    end
  end

  describe "the transcript" do
    test "events are numbered, persisted and replayable" do
      id = new_session()
      Agent.submit(id, "hello")
      BackendStub.await_turn()

      backend_sends(id, [
        {:event, :status, %{status: :running}},
        {:event, :assistant_text, %{block_id: "b1", text: "hi there"}}
      ])

      {:ok, snapshot} = Agent.attach(id, 0)
      kinds = Enum.map(snapshot.events, & &1.kind)
      assert :user in kinds
      assert :assistant_text in kinds

      seqs = Enum.map(snapshot.events, & &1.seq)
      assert seqs == Enum.sort(seqs)
      assert snapshot.last_seq == List.last(seqs)

      # And they survive the process.
      assert Enum.any?(Store.read_events(id, 100), &(&1.kind == :assistant_text))
    end

    test "attaching with a seq returns only what was missed" do
      id = new_session()
      Agent.submit(id, "one")
      BackendStub.await_turn()
      {:ok, first} = Agent.attach(id, 0)

      backend_sends(id, [{:event, :assistant_text, %{block_id: "b1", text: "later"}}])

      {:ok, delta} = Agent.attach(id, first.last_seq)
      assert Enum.all?(delta.events, &(&1.seq > first.last_seq))
      assert Enum.any?(delta.events, &(&1.kind == :assistant_text))
    end

    test "deltas are broadcast but never persisted" do
      id = new_session()
      Phoenix.PubSub.subscribe(Loom.PubSub, Agent.topic(id))
      Agent.submit(id, "hello")
      BackendStub.await_turn()

      backend_sends(id, [{:delta, %{block_id: "b1", type: :text, chunk: "hi"}}])

      assert_receive {:agent_delta, ^id, %{block_id: "b1", chunk: "hi"}}, 500
      # A client that missed it gets the authoritative event instead, so there
      # is nothing to replay.
      refute Enum.any?(Store.read_events(id, 100), &(&1.kind == :text))
    end

    test "a failed turn is reported and ends the turn" do
      id = new_session()
      Phoenix.PubSub.subscribe(Loom.PubSub, Agent.topic(id))
      Agent.submit(id, "go")
      BackendStub.await_turn()

      backend_sends(id, [{:event, :turn_failed, %{reason: "the app-server restarted mid-turn"}}])

      assert_receive {:agent_event, ^id, %{kind: :error, payload: %{message: message}}}, 500
      assert message =~ "restarted"
      assert Agent.info(id).status == :idle
    end

    test "a failed turn still drains a waiting queue" do
      # The user's follow-up should not be stranded by a backend hiccup.
      id = new_session()
      Agent.submit(id, "go")
      BackendStub.await_turn()
      BackendStub.fail_next_steer()
      Agent.submit(id, "and then this")

      backend_sends(id, [{:event, :turn_failed, %{reason: "boom"}}])

      assert BackendStub.await_turn() == "and then this"
    end
  end

  describe "keeping the backend warm" do
    # Claude Code holds a ~275 MB process so later turns start in 0.02 s rather
    # than 6 s. Worth paying while someone works, pure waste once they leave.

    test "a finished turn schedules a release, and a new turn cancels it" do
      id = new_session()
      [{pid, _}] = Registry.lookup(Loom.Agent.Registry, id)

      Agent.submit(id, "go")
      BackendStub.await_turn()
      finish_turn(id)
      assert :sys.get_state(pid).release_timer != nil

      Agent.submit(id, "again")
      BackendStub.await_turn()
      # Releasing mid-turn would kill the process out from under it.
      assert :sys.get_state(pid).release_timer == nil
    end

    test "the timer firing releases the backend" do
      id = new_session()
      [{pid, _}] = Registry.lookup(Loom.Agent.Registry, id)
      Agent.submit(id, "go")
      BackendStub.await_turn()
      finish_turn(id)

      send(pid, :release_backend)
      assert_receive :stub_released, 500
    end

    test "a release that lands mid-turn is ignored" do
      # The timer can fire just as a turn starts; killing the process then would
      # abort work in flight.
      id = new_session()
      [{pid, _}] = Registry.lookup(Loom.Agent.Registry, id)
      Agent.submit(id, "go")
      BackendStub.await_turn()

      send(pid, :release_backend)
      refute_receive :stub_released, 200
      assert Agent.info(id).status == :starting
    end

    test "an interrupted session also releases eventually" do
      id = new_session()
      [{pid, _}] = Registry.lookup(Loom.Agent.Registry, id)
      Agent.submit(id, "go")
      BackendStub.await_turn()
      Agent.interrupt(id)

      assert :sys.get_state(pid).release_timer != nil
    end
  end

  describe "usage" do
    test "comes from the backend's own report, latest wins" do
      # Context is a size, not a running total: each turn replaces it rather
      # than adding to it. See `Loom.Agent.Backend.ClaudeCode.context_of/1`.
      id = new_session()
      Agent.submit(id, "go")
      BackendStub.await_turn()

      finish_turn(id, %{
        context_tokens: 15_000,
        context_window: 258_400,
        usage: %{"output_tokens" => 7}
      })

      info = Agent.info(id)
      assert info.context_tokens == 15_000
      assert info.context_window == 258_400
      assert info.turns == 1

      Agent.submit(id, "again")
      BackendStub.await_turn()
      finish_turn(id, %{context_tokens: 21_000})

      info = Agent.info(id)
      assert info.context_tokens == 21_000
      # Carried over: a turn that does not report it has not changed it.
      assert info.context_window == 258_400
      assert info.turns == 2
    end
  end

  describe "status broadcasting" do
    test "a second device sees every transition" do
      # A phone that joins mid-turn learns the status from the snapshot; from
      # then on it only hears about changes as events.
      id = new_session()
      Phoenix.PubSub.subscribe(Loom.PubSub, Agent.topic(id))

      Agent.submit(id, "go")
      BackendStub.await_turn()
      assert_receive {:agent_event, ^id, %{kind: :status, payload: %{status: :starting}}}, 500

      backend_sends(id, [{:event, :status, %{status: :running}}])
      assert_receive {:agent_event, ^id, %{kind: :status, payload: %{status: :running}}}, 500

      finish_turn(id)
      assert_receive {:agent_event, ^id, %{kind: :status, payload: %{status: :idle}}}, 500
    end

    test "a parked message is broadcast so every device shows it" do
      id = new_session()
      Phoenix.PubSub.subscribe(Loom.PubSub, Agent.topic(id))
      Agent.submit(id, "go")
      BackendStub.await_turn()
      BackendStub.fail_next_steer()
      Agent.submit(id, "parked")

      assert_receive {:agent_event, ^id, %{kind: :queue, payload: %{queued: 1}}}, 500
    end
  end
end
