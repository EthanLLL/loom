defmodule Loom.Terminal.Session do
  @moduledoc """
  Owns a single PTY (via ExPTY) running a shell. Decoupled from any websocket:
  the PTY keeps running even if the browser disconnects, so a client can leave
  and later reattach to the same live shell.

  A single subscriber process (the channel) receives `{:pty_output, binary}`.
  Recent output is kept in a bounded ring buffer and replayed to a subscriber
  on attach, so a reconnecting client sees the current screen instead of blank.
  """
  use GenServer, restart: :transient

  require Logger

  @default_shell System.get_env("SHELL") || "/bin/zsh"
  # Bytes of recent output retained for replay-on-reconnect.
  @buffer_limit 256 * 1024

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :id)))
  end

  @doc """
  Register `pid` as the subscriber. Immediately replays the retained output
  buffer to `pid` (as a `{:pty_output, binary}`) so it can rebuild the screen.
  """
  def subscribe(id, pid), do: GenServer.call(via(id), {:subscribe, pid})

  @doc "Send raw keystrokes to the shell's stdin."
  def send_input(id, data), do: GenServer.cast(via(id), {:input, data})

  @doc "Resize the PTY (triggers SIGWINCH)."
  def resize(id, cols, rows), do: GenServer.cast(via(id), {:resize, cols, rows})

  @doc "Return metadata about the session."
  def info(id), do: GenServer.call(via(id), :info)

  def via(id), do: {:via, Registry, {Loom.Terminal.Registry, id}}

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    cols = Keyword.get(opts, :cols, 80)
    rows = Keyword.get(opts, :rows, 24)
    shell = Keyword.get(opts, :shell, @default_shell)
    title = Keyword.get(opts, :title)

    env =
      System.get_env()
      |> Map.put("TERM", "xterm-256color")
      |> Map.put("COLORTERM", "truecolor")

    parent = self()

    {:ok, pty} =
      ExPTY.spawn(shell, ["-l"],
        cols: cols,
        rows: rows,
        name: "xterm-256color",
        encoding: "utf-8",
        env: env,
        # Prevent the shell from inheriting our fds (e.g. Phoenix's :4000
        # listen socket), which would otherwise keep the port held after the
        # server stops until every session shell also exits.
        closeFDs: true,
        on_data: fn _pty, _pid, data -> send(parent, {:pty_data, data}) end,
        on_exit: fn _pty, _pid, _code, _signal -> send(parent, :pty_exit) end
      )

    state = %{
      id: id,
      pty: pty,
      title: title,
      created_at: System.system_time(:millisecond),
      cols: cols,
      rows: rows,
      subscriber: nil,
      monitor: nil,
      buffer: "",
      buffer_size: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    if state.subscriber && state.subscriber != pid && state.monitor do
      Process.demonitor(state.monitor, [:flush])
    end

    ref = Process.monitor(pid)
    # Replay retained output so the client rebuilds the current screen.
    if state.buffer_size > 0, do: send(pid, {:pty_output, state.buffer})

    {:reply, :ok, %{state | subscriber: pid, monitor: ref}}
  end

  def handle_call(:info, _from, state) do
    {:reply, session_info(state), state}
  end

  @impl true
  def handle_cast({:input, data}, state) do
    ExPTY.write(state.pty, data)
    {:noreply, state}
  end

  def handle_cast({:resize, cols, rows}, state) do
    ExPTY.resize(state.pty, cols, rows)
    {:noreply, %{state | cols: cols, rows: rows}}
  end

  @impl true
  def handle_info({:pty_data, data}, state) do
    output = Loom.Terminal.Sgr.transform(data)

    if output == "" do
      {:noreply, state}
    else
      if state.subscriber, do: send(state.subscriber, {:pty_output, output})
      {:noreply, append_buffer(state, output)}
    end
  end

  def handle_info(:pty_exit, state) do
    Logger.info("PTY for session #{state.id} exited, stopping")
    {:stop, :normal, state}
  end

  # Subscriber (channel) went away — keep the PTY alive for reconnect.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{subscriber: pid} = state) do
    {:noreply, %{state | subscriber: nil, monitor: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp append_buffer(state, output) do
    buffer = state.buffer <> output
    size = state.buffer_size + byte_size(output)

    if size > @buffer_limit do
      # Keep the most recent @buffer_limit bytes. A stray partial escape at the
      # new front is harmless — xterm ignores it during replay.
      trimmed = binary_part(buffer, size - @buffer_limit, @buffer_limit)
      %{state | buffer: trimmed, buffer_size: @buffer_limit}
    else
      %{state | buffer: buffer, buffer_size: size}
    end
  end

  defp session_info(state) do
    %{
      id: state.id,
      title: state.title,
      created_at: state.created_at,
      cols: state.cols,
      rows: state.rows
    }
  end
end
