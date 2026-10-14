defmodule Loom.BackendStub do
  @moduledoc """
  A `Loom.Agent.Backend` that reports what it was asked to do and emits whatever
  the test tells it to.

  Session tests are about the queue, status transitions and persistence — none of
  which should need a real `claude` or `codex` to exercise. The adapters have
  their own tests against recorded protocol output.

  The test drives output by sending `{:stub, out}` straight to the session
  process: the session forwards anything it does not recognise to `decode/2`,
  which hands the list back untouched. So a test can produce any event sequence,
  in any order, including ones a real backend would never emit.
  """

  @behaviour Loom.Agent.Backend

  use GenServer

  # ── Test API ──────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Block until a turn is started, returning the text the session merged."
  def await_turn(timeout \\ 1_000) do
    receive do
      {:stub_turn, text} -> text
    after
      timeout -> raise "no turn started within #{timeout}ms"
    end
  end

  @doc "Assert no turn was started."
  def refute_turn(timeout \\ 100) do
    receive do
      {:stub_turn, text} -> raise "a turn was started with #{inspect(text)}"
    after
      timeout -> :ok
    end
  end

  @doc "Block until a message is steered into a running turn."
  def await_steer(timeout \\ 1_000) do
    receive do
      {:stub_steer, text} -> text
    after
      timeout -> raise "nothing was steered within #{timeout}ms"
    end
  end

  @doc "Assert nothing was steered."
  def refute_steer(timeout \\ 100) do
    receive do
      {:stub_steer, text} -> raise "a message was steered: #{inspect(text)}"
    after
      timeout -> :ok
    end
  end

  @doc "Make the next `run_turn/2` fail."
  def fail_next_turn, do: GenServer.call(__MODULE__, :fail_next_turn)

  @doc """
  Make the next `steer/2` fail, as Codex does when the turn ended under us.
  """
  def fail_next_steer, do: GenServer.call(__MODULE__, :fail_next_steer)

  @doc "Make the next `resume/2` fail, as a locked codex thread would."
  def fail_next_resume, do: GenServer.call(__MODULE__, :fail_next_resume)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       notify: opts[:notify],
       fail_turn: false,
       fail_resume: false,
       fail_steer: false,
       released: 0
     }}
  end

  @impl GenServer
  def handle_call(:fail_next_turn, _from, state), do: {:reply, :ok, %{state | fail_turn: true}}

  def handle_call(:fail_next_resume, _from, state),
    do: {:reply, :ok, %{state | fail_resume: true}}

  def handle_call({:turn, text}, _from, state) do
    if state.notify, do: send(state.notify, {:stub_turn, text})

    if state.fail_turn do
      {:reply, {:error, "stub refused"}, %{state | fail_turn: false}}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(:interrupted, _from, state) do
    if state.notify, do: send(state.notify, :stub_interrupt)
    {:reply, :ok, state}
  end

  def handle_call(:fail_next_steer, _from, state), do: {:reply, :ok, %{state | fail_steer: true}}

  def handle_call({:steer, text}, _from, state) do
    if state.fail_steer do
      {:reply, {:error, "stub refused to steer"}, %{state | fail_steer: false}}
    else
      if state.notify, do: send(state.notify, {:stub_steer, text})
      {:reply, :ok, state}
    end
  end

  def handle_call(:released, _from, state) do
    if state.notify, do: send(state.notify, :stub_released)
    {:reply, :ok, %{state | released: state.released + 1}}
  end

  def handle_call(:resuming, _from, state) do
    if state.fail_resume do
      {:reply, {:error, "stub refused to resume"}, %{state | fail_resume: false}}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(:stopped, _from, state) do
    if state.notify, do: send(state.notify, :stub_stopped)
    {:reply, :ok, state}
  end

  # ── Backend ───────────────────────────────────────────────────────────────

  @impl Loom.Agent.Backend
  def start(session_id, _meta), do: {:ok, %{session_id: session_id, ref: "stub-#{session_id}"}}

  @impl Loom.Agent.Backend
  def resume(session_id, %{stub_ref: ref}) when is_binary(ref) do
    case GenServer.call(__MODULE__, :resuming) do
      :ok -> {:ok, %{session_id: session_id, ref: ref}}
      {:error, reason} -> {:error, reason}
    end
  end

  def resume(_session_id, _meta), do: {:error, "no stub_ref recorded"}

  @impl Loom.Agent.Backend
  def run_turn(handle, text) do
    case GenServer.call(__MODULE__, {:turn, text}) do
      :ok -> {:ok, handle}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Loom.Agent.Backend
  def steer(handle, text) do
    case GenServer.call(__MODULE__, {:steer, text}) do
      :ok -> {:ok, handle}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Loom.Agent.Backend
  def release(handle) do
    :ok = GenServer.call(__MODULE__, :released)
    {:ok, handle}
  end

  @impl Loom.Agent.Backend
  def interrupt(handle) do
    :ok = GenServer.call(__MODULE__, :interrupted)
    {:ok, handle}
  end

  @impl Loom.Agent.Backend
  def decode(handle, {:stub, out}), do: {:ok, handle, out}
  def decode(_handle, _message), do: :ignore

  @impl Loom.Agent.Backend
  def persist(handle), do: %{stub_ref: handle.ref}

  @impl Loom.Agent.Backend
  def stop(_handle) do
    :ok = GenServer.call(__MODULE__, :stopped)
    :ok
  catch
    # The stub may already be gone during test teardown; a real backend's stop
    # has to be just as forgiving.
    _, _ -> :ok
  end
end
