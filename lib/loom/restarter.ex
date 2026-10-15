defmodule Loom.Restarter do
  @moduledoc """
  Restart loom once every agent session is idle.

  The agent that deploys loom runs *inside* loom: restarting the node from a
  turn kills that turn mid-sentence. So the agent asks for a restart instead,
  finishes its reply, and the node goes down only when no session — its own
  included — has a turn running. systemd (`Restart=always`) brings it back, and
  `rel/systemd/promote-next.sh` swaps in a staged release on the way up.

      bin/loom rpc 'IO.inspect(Loom.Restarter.request())'

  Idleness comes from the lobby (`Loom.Agent.lobby_topic/0`), not from polling
  the sessions.

  Deliberately forgetful: a pending request lives only in this process, so the
  restart it causes also erases it, and nothing can ask for the next one. If the
  sessions never all go idle, the request expires and loom stays up — this never
  forces a restart over a running turn.
  """
  use GenServer

  require Logger

  alias Loom.Agent

  @default_timeout_ms :timer.minutes(10)

  # Idle is re-checked after this long before stopping: a turn's final events
  # are still on their way to the browser when its status flips to idle, and a
  # user may be mid-way through sending the next message.
  @settle_ms 2_000

  @busy [:starting, :running]

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Ask for a restart as soon as every session is idle.

  Returns `{:ok, :pending, busy_session_ids}`, or `{:ok, :already_pending}` if
  a request is already waiting. `:timeout_ms` overrides how long to wait before
  giving up.
  """
  def request(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:request, Keyword.get(opts, :timeout_ms, @default_timeout_ms)})
  end

  @doc "Withdraw a pending request."
  def cancel(server \\ __MODULE__), do: GenServer.call(server, :cancel)

  @doc "`:idle`, or `{:pending, busy_session_ids}`."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    {:ok,
     %{
       # Injectable so tests can observe the stop instead of suffering it.
       stop: Keyword.get(opts, :stop, &System.stop/0),
       settle_ms: Keyword.get(opts, :settle_ms, @settle_ms),
       pending: false,
       # id => {seq, status}, for every live session while a request is pending.
       sessions: %{},
       timeout: nil,
       settle: nil
     }}
  end

  @impl true
  def handle_call({:request, _timeout_ms}, _from, %{pending: true} = state) do
    {:reply, {:ok, :already_pending}, state}
  end

  def handle_call({:request, timeout_ms}, _from, state) do
    # Subscribe before reading the list, so a change in between is not missed;
    # `seq` sorts out any summary that turns out older than the list.
    :ok = Phoenix.PubSub.subscribe(Loom.PubSub, Agent.lobby_topic())

    sessions = Map.new(Agent.list_sessions(), &{&1.id, {&1.seq, &1.status}})

    state = %{
      state
      | pending: true,
        sessions: sessions,
        timeout: Process.send_after(self(), :give_up, timeout_ms)
    }

    Logger.info("Loom.Restarter: restart requested; waiting on #{inspect(busy(state))}")
    {:reply, {:ok, :pending, busy(state)}, maybe_settle(state)}
  end

  def handle_call(:cancel, _from, state) do
    Logger.info("Loom.Restarter: restart request cancelled")
    {:reply, :ok, clear(state)}
  end

  def handle_call(:status, _from, %{pending: false} = state), do: {:reply, :idle, state}
  def handle_call(:status, _from, state), do: {:reply, {:pending, busy(state)}, state}

  @impl true
  def handle_info({:agent_summary, %{id: id, seq: seq, status: status}}, %{pending: true} = state) do
    sessions =
      Map.update(state.sessions, id, {seq, status}, fn {known, _} = old ->
        if seq >= known, do: {seq, status}, else: old
      end)

    {:noreply, maybe_settle(%{state | sessions: sessions})}
  end

  def handle_info({:agent_removed, id}, %{pending: true} = state) do
    {:noreply, maybe_settle(%{state | sessions: Map.delete(state.sessions, id)})}
  end

  def handle_info(:settled, %{pending: true} = state) do
    state = %{state | settle: nil}

    if busy(state) == [] do
      Logger.info("Loom.Restarter: every session is idle; stopping for restart")
      state.stop.()
      {:noreply, clear(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:give_up, %{pending: true} = state) do
    Logger.warning(
      "Loom.Restarter: gave up waiting; still busy: #{inspect(busy(state))}. Not restarting."
    )

    {:noreply, clear(state)}
  end

  # Lobby traffic after a cancel, or a timer that fired as it was cancelled.
  def handle_info(_message, state), do: {:noreply, state}

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp busy(state) do
    for {id, {_seq, status}} <- state.sessions, status in @busy, do: id
  end

  # Idle now: check again shortly rather than stopping on the spot. Busy again:
  # drop any pending check, so a turn starting in the window is not cut off.
  defp maybe_settle(state) do
    case {busy(state), state.settle} do
      {[], nil} ->
        %{state | settle: Process.send_after(self(), :settled, state.settle_ms)}

      {[], _armed} ->
        state

      {_busy, nil} ->
        state

      {_busy, ref} ->
        Process.cancel_timer(ref)
        %{state | settle: nil}
    end
  end

  defp clear(state) do
    Phoenix.PubSub.unsubscribe(Loom.PubSub, Agent.lobby_topic())
    if state.timeout, do: Process.cancel_timer(state.timeout)
    if state.settle, do: Process.cancel_timer(state.settle)
    %{state | pending: false, sessions: %{}, timeout: nil, settle: nil}
  end
end
