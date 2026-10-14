defmodule LoomWeb.AgentChannelTest do
  @moduledoc """
  The wire contract the browser client is written against.

  The client's state machine depends on three things holding: the join reply
  carries a snapshot it can start from, events arrive with a monotonic `seq` so a
  reconnect can ask for only the gap, and deltas arrive separately with a
  `block_id` it can match against the event that supersedes them.
  """
  use LoomWeb.ChannelCase, async: false

  alias Loom.Agent
  alias Loom.BackendStub
  alias LoomWeb.AgentChannel
  alias LoomWeb.UserSocket

  setup do
    data_dir = Path.join(System.tmp_dir!(), "loom-chan-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:loom, Loom.Agent, [])

    Application.put_env(
      :loom,
      Loom.Agent,
      previous
      |> Keyword.put(:data_dir, data_dir)
      |> Keyword.put(:backends, %{claude_code: BackendStub, codex: BackendStub})
    )

    start_supervised!({BackendStub, notify: self()})

    id = "a_chan_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Agent.start_session(id, backend: :claude_code)

    on_exit(fn ->
      for %{id: live} <- Agent.list_sessions(), do: Agent.stop_session(live)
      Process.sleep(50)
      Application.put_env(:loom, Loom.Agent, previous)
      File.rm_rf(data_dir)
    end)

    {:ok, id: id}
  end

  defp attach(id, params \\ %{}) do
    socket(UserSocket, nil, %{})
    |> subscribe_and_join(AgentChannel, "agent:#{id}", params)
  end

  defp backend_sends(id, out) do
    [{pid, _}] = Registry.lookup(Loom.Agent.Registry, id)
    send(pid, {:stub, out})
    _ = Agent.info(id)
    :ok
  end

  describe "joining" do
    test "the reply is a snapshot the client can start from", %{id: id} do
      assert {:ok, snapshot, _socket} = attach(id)

      assert snapshot.meta.id == id
      assert snapshot.meta.status == :idle
      assert snapshot.meta.backend == :claude_code
      assert is_integer(snapshot.last_seq)
      assert is_list(snapshot.events)
    end

    test "joining with since_seq returns only the gap", %{id: id} do
      {:ok, first, socket} = attach(id)
      Process.unlink(socket.channel_pid)
      leave(socket)

      Agent.submit(id, "while away")
      BackendStub.await_turn()

      assert {:ok, snapshot, _socket} = attach(id, %{"since_seq" => first.last_seq})
      assert Enum.all?(snapshot.events, &(&1.seq > first.last_seq))
      assert Enum.any?(snapshot.events, &(&1.kind == :user))
    end

    test "joining a session that does not exist is refused" do
      assert {:error, _} = attach("a_not_a_session")
    end
  end

  describe "submitting" do
    test "an idle session reports the turn started", %{id: id} do
      {:ok, _snapshot, socket} = attach(id)

      ref = push(socket, "submit", %{"text" => "hello", "client_msg_id" => "c1"})
      assert_reply ref, :ok, %{status: :started}

      assert BackendStub.await_turn() == "hello"
      # The client reconciles its optimistic bubble by client_msg_id.
      assert_push "event", %{kind: :user, payload: %{client_msg_id: "c1", status: :sent}}
    end

    test "a message sent mid-turn reports that it joined the turn", %{id: id} do
      {:ok, _snapshot, socket} = attach(id)
      push(socket, "submit", %{"text" => "first"})
      BackendStub.await_turn()

      ref = push(socket, "submit", %{"text" => "second"})
      assert_reply ref, :ok, %{status: :steered}

      assert BackendStub.await_steer() == "second"
    end

    test "a refused steer comes back queued and is broadcast", %{id: id} do
      {:ok, _snapshot, socket} = attach(id)
      push(socket, "submit", %{"text" => "first"})
      BackendStub.await_turn()
      BackendStub.fail_next_steer()

      ref = push(socket, "submit", %{"text" => "second"})
      assert_reply ref, :ok, %{status: :queued}
      assert_push "event", %{kind: :queue, payload: %{queued: 1}}
    end

    test "a submit with no text is rejected rather than crashing the channel", %{id: id} do
      {:ok, _snapshot, socket} = attach(id)
      ref = push(socket, "submit", %{})
      assert_reply ref, :error, %{reason: reason}
      assert reason =~ "text"
    end
  end

  describe "interrupting" do
    test "stops the turn and keeps anything parked", %{id: id} do
      {:ok, _snapshot, socket} = attach(id)
      push(socket, "submit", %{"text" => "a long job"})
      BackendStub.await_turn()
      BackendStub.fail_next_steer()
      push(socket, "submit", %{"text" => "parked"})

      ref = push(socket, "interrupt", %{})
      assert_reply ref, :ok

      assert_push "event", %{kind: :status, payload: %{status: :interrupted, queued: 1}}
      BackendStub.refute_turn()
    end

    test "a parked message can be dropped from the client", %{id: id} do
      {:ok, _snapshot, socket} = attach(id)
      push(socket, "submit", %{"text" => "running"})
      BackendStub.await_turn()
      BackendStub.fail_next_steer()
      push(socket, "submit", %{"text" => "stale"})
      assert_push "event", %{kind: :queue, payload: %{queued: 1}}

      ref = push(socket, "drop_queued", %{"index" => 0})
      assert_reply ref, :ok
      assert_push "event", %{kind: :queue, payload: %{queued: 0}}
    end

    test "dropping an index that is not there is an error, not a crash", %{id: id} do
      {:ok, _snapshot, socket} = attach(id)
      ref = push(socket, "drop_queued", %{"index" => 7})
      assert_reply ref, :error, %{reason: "out_of_range"}
    end
  end

  describe "renaming" do
    test "is accepted and broadcast", %{id: id} do
      {:ok, _snapshot, socket} = attach(id)

      ref = push(socket, "rename", %{"title" => "the good branch"})
      assert_reply ref, :ok
      assert_push "event", %{kind: :renamed, payload: %{title: "the good branch"}}
    end

    test "an empty title is refused", %{id: id} do
      {:ok, _snapshot, socket} = attach(id)
      ref = push(socket, "rename", %{"title" => "   "})
      assert_reply ref, :error, %{reason: "empty"}
    end
  end

  describe "the two layers reaching the client" do
    test "events are pushed with a monotonic seq", %{id: id} do
      {:ok, snapshot, _socket} = attach(id)
      Agent.submit(id, "hello")
      BackendStub.await_turn()

      assert_push "event", %{kind: :user, seq: first_seq}
      assert first_seq > snapshot.last_seq

      backend_sends(id, [{:event, :assistant_text, %{block_id: "b1", text: "hi"}}])
      assert_push "event", %{kind: :assistant_text, seq: later_seq}
      assert later_seq > first_seq
    end

    test "deltas arrive on their own channel event, matchable by block_id", %{id: id} do
      {:ok, _snapshot, _socket} = attach(id)
      Agent.submit(id, "hello")
      BackendStub.await_turn()

      backend_sends(id, [
        {:delta, %{block_id: "b1", type: :block_start, block_type: :text}},
        {:delta, %{block_id: "b1", type: :text, chunk: "hi"}},
        {:event, :assistant_text, %{block_id: "b1", text: "hi"}}
      ])

      assert_push "delta", %{block_id: "b1", type: :block_start}
      assert_push "delta", %{block_id: "b1", type: :text, chunk: "hi"}
      # Same block_id, so the client replaces the placeholder rather than
      # appending a duplicate.
      assert_push "event", %{kind: :assistant_text, payload: %{block_id: "b1"}}
    end

    test "streaming tool output reaches the client under the tool card's id", %{id: id} do
      {:ok, _snapshot, _socket} = attach(id)
      Agent.submit(id, "build it")
      BackendStub.await_turn()

      backend_sends(id, [
        {:event, :tool_use, %{id: "t1", block_id: "t1", name: "shell", input: %{}}},
        {:delta, %{block_id: "t1", type: :tool_output, chunk: "compiling...\n"}}
      ])

      assert_push "event", %{kind: :tool_use, payload: %{block_id: "t1"}}
      assert_push "delta", %{block_id: "t1", type: :tool_output, chunk: "compiling...\n"}
    end

    test "two devices both see every status transition", %{id: id} do
      {:ok, _s1, _one} = attach(id)
      Phoenix.PubSub.subscribe(Loom.PubSub, Agent.topic(id))

      Agent.submit(id, "go")
      BackendStub.await_turn()

      assert_push "event", %{kind: :status, payload: %{status: :starting}}
      assert_receive {:agent_event, ^id, %{kind: :status, payload: %{status: :starting}}}
    end
  end
end
