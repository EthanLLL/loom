defmodule Loom.Terminal.Session do
  @moduledoc """
  Owns a single PTY (via ExPTY) running a shell. Decoupled from any websocket:
  the PTY keeps running even if the browser disconnects, so a client can leave
  and later reattach to the same live shell.

  Every attached client (one channel per browser tab) receives
  `{:pty_output, binary}`. Recent output is kept in a bounded ring buffer and
  replayed to a client on attach, so a reconnecting client sees the current
  screen instead of blank.

  ## Several clients, one shell

  Input needs nothing special: every keystroke frame is a cast into this
  process, so two people typing at once interleave frame by frame — like two
  hands on one keyboard — and no frame is ever split.

  What does need care is that a PTY has one of everything a terminal has, and
  each client is a whole terminal:

    * **One size.** A phone at 40 columns and a laptop at 200 cannot both be
      right. The size follows the *driver*, the client that most recently
      typed — tmux's `window-size latest`. Whoever is using the shell sees it
      laid out correctly; a client that is only watching may see it wrap.
    * **One reply per query.** A TUI asks the terminal things (cursor position,
      device attributes, colours) and every xterm.js attached answers. A second
      answer arrives as stray input — `^[[12;1R` printed at the prompt. So a
      frame made only of such replies is dropped unless it comes from the
      driver, and does not make its sender the driver.

  Replay is sent from inside the attach call, so nothing the shell prints can
  land between the buffer and the live stream — which is why clients are kept
  here rather than on a PubSub topic, where subscribing and fetching the buffer
  are two steps with output in between.
  """
  use GenServer, restart: :transient

  require Logger

  # Bytes of recent output retained for replay-on-reconnect.
  @buffer_limit 256 * 1024

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :id)))
  end

  @doc """
  Attach `pid` as a client, `size` being its `{cols, rows}` if known.

  Immediately replays the retained output buffer to `pid` (as a
  `{:pty_output, binary}`) so it can rebuild the screen. The newcomer becomes
  the driver: whoever just opened a terminal is the one about to use it.
  """
  def subscribe(id, pid, size \\ nil), do: GenServer.call(via(id), {:subscribe, pid, size})

  @doc "Send raw keystrokes from client `pid` to the shell's stdin."
  def send_input(id, pid, data), do: GenServer.cast(via(id), {:input, pid, data})

  @doc """
  Record client `pid`'s size. Resizes the PTY (SIGWINCH) only if `pid` is the
  driver, or nobody is.
  """
  def resize(id, pid, cols, rows), do: GenServer.cast(via(id), {:resize, pid, cols, rows})

  @doc "Return metadata about the session."
  def info(id), do: GenServer.call(via(id), :info)

  def via(id), do: {:via, Registry, {Loom.Terminal.Registry, id}}

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # Trap exits so `terminate/2` runs on supervisor shutdown — that is where we
    # kill the PTY. ExPTY is started with `GenServer.start` (NOT `start_link`),
    # so it is NOT linked to us: when this Session dies, the ExPTY process, its
    # PTY, and the shell all keep running unless we explicitly kill them.
    Process.flag(:trap_exit, true)
    id = Keyword.fetch!(opts, :id)
    cols = Keyword.get(opts, :cols, 80)
    rows = Keyword.get(opts, :rows, 24)
    shell = Keyword.get_lazy(opts, :shell, &default_shell/0)
    title = Keyword.get(opts, :title)

    env =
      Loom.ChildEnv.map()
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

    # The shell's OS pid. ExPTY spawns it via forkpty + setsid(), so the shell
    # leads its own session — which is what `terminate/2` kills. See there.
    os_pid =
      try do
        :sys.get_state(pty).pid
      catch
        _, _ -> nil
      end

    state = %{
      id: id,
      pty: pty,
      os_pid: os_pid,
      title: title,
      created_at: System.system_time(:millisecond),
      cols: cols,
      rows: rows,
      # pid => %{ref: monitor, size: {cols, rows} | nil}
      clients: %{},
      driver: nil,
      buffer: "",
      buffer_size: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid, size}, _from, state) do
    client =
      case state.clients do
        %{^pid => client} -> %{client | size: size || client.size}
        _ -> %{ref: Process.monitor(pid), size: size}
      end

    # Replay retained output so the client rebuilds the current screen.
    if state.buffer_size > 0, do: send(pid, {:pty_output, state.buffer})

    state = put_in(state.clients[pid], client)
    {:reply, :ok, drive(state, pid)}
  end

  def handle_call(:info, _from, state) do
    {:reply, session_info(state), state}
  end

  @impl true
  def handle_cast({:input, pid, data}, state) do
    cond do
      pid == state.driver ->
        ExPTY.write(state.pty, data)
        {:noreply, state}

      reply_only?(data) ->
        {:noreply, state}

      true ->
        ExPTY.write(state.pty, data)
        {:noreply, drive(state, pid)}
    end
  end

  def handle_cast({:resize, pid, cols, rows}, state) do
    case state.clients do
      %{^pid => _} ->
        state = put_in(state.clients[pid].size, {cols, rows})
        if state.driver in [nil, pid], do: {:noreply, drive(state, pid)}, else: {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:pty_data, data}, state) do
    output = Loom.Terminal.Sgr.transform(data)

    if output == "" do
      {:noreply, state}
    else
      for {pid, _} <- state.clients, do: send(pid, {:pty_output, output})
      {:noreply, append_buffer(state, output)}
    end
  end

  def handle_info(:pty_exit, state) do
    Logger.info("PTY for session #{state.id} exited, stopping")
    {:stop, :normal, state}
  end

  # A client went away — keep the PTY alive for reconnect. If it was driving,
  # hand the wheel to someone still here, so the size fits a screen that is
  # actually looking at it.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state)
      when is_map_key(state.clients, pid) do
    {_, clients} = Map.pop(state.clients, pid)
    state = %{state | clients: clients}

    cond do
      state.driver != pid -> {:noreply, state}
      clients == %{} -> {:noreply, %{state | driver: nil}}
      true -> {:noreply, drive(state, clients |> Map.keys() |> hd())}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Closing a tab/pane calls DynamicSupervisor.terminate_child, which lands
    # here. Without this the PTY + shell (+ any TUI in it) would keep running
    # forever, since ExPTY is unlinked (it uses GenServer.start, not start_link).
    #
    # If ExPTY is still alive, the shell hasn't exited on its own, so os_pid is
    # still valid (not yet reaped/reused): kill everything in the shell's
    # *session*. The shell is a session leader (forkpty + setsid), and its async
    # workers re-parent to init but stay in that session. Killing only the
    # process group is not enough: powerlevel10k puts its gitstatusd workers in
    # process groups of their own, and they hold the PTY open — so they leaked
    # one set per closed terminal, and kept a `mix test` node from ever exiting.
    # If ExPTY already died (:pty_exit), the child is already gone — skip the
    # kill to avoid SIGKILLing an unrelated session that reused the pid.
    if Process.alive?(state.pty) do
      if state.os_pid && state.os_pid > 1 do
        System.cmd("pkill", ["-KILL", "-s", "#{state.os_pid}"], stderr_to_stdout: true)
        System.cmd("kill", ["-KILL", "-#{state.os_pid}"], stderr_to_stdout: true)
      end

      ExPTY.kill(state.pty, 9)
      GenServer.stop(state.pty, :normal, 1_000)
    end

    :ok
  catch
    _, _ -> :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Make `pid` the driver and fit the PTY to it.
  defp drive(state, pid) do
    case state.clients[pid] do
      %{size: {cols, rows}} when {cols, rows} != {state.cols, state.rows} ->
        ExPTY.resize(state.pty, cols, rows)
        %{state | driver: pid, cols: cols, rows: rows}

      _ ->
        %{state | driver: pid}
    end
  end

  # What xterm.js sends on its own, answering the program rather than the
  # user: cursor position and status reports (CSI … R / n), device attributes
  # (CSI ? … c, CSI > … c), mode reports (CSI … $ y), window reports (CSI … t),
  # keyboard protocol (CSI ? … u), focus in/out (CSI I / O), OSC replies such as
  # colours, and DCS replies such as XTGETTCAP. Only frames made *entirely* of
  # these count, so a keystroke is never dropped — the one overlap, Ctrl+F3
  # also being CSI 1;5 R, is lost only from a client that is not driving.
  @reply ~r/\A(?:\e\[\??[\d;]*[Rn]|\e\[[\d;]*t|\e\[[?>=][\d;]*c|\e\[\?[\d;]*u|\e\[\??[\d;]*\$y|\e\[[IO]|\e\][^\a\e]*(?:\a|\e\\)|\eP[^\e]*\e\\)+\z/

  defp reply_only?(data), do: Regex.match?(@reply, data)

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

  # Read when a terminal opens, not when this module compiles: a module
  # attribute would bake in the `SHELL` of whoever ran `mix release`.
  defp default_shell, do: System.get_env("SHELL") || "/bin/zsh"
end
