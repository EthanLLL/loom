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

  ## On a device

  Given `node:` (a device's name) and `channel:` (its `LoomWeb.NodeChannel`),
  the shell runs there instead: `loom-node` opens a PTY with the device's login
  shell, and its bytes come and go over that channel, the session's id being
  the request id. Everything above — replay, several clients, the driver's
  size — is the same, since it all happens here.

  The device hangs up the shell when its connection drops, as it does to a
  command. The session then stays, saying so on screen, until it is closed:
  a pane that just vanished would leave no clue why.
  """
  use GenServer, restart: :transient

  require Logger

  # Bytes of recent output retained for replay-on-reconnect.
  @buffer_limit 256 * 1024

  # How long a device has to say it opened the terminal. One whose loom-node
  # predates terminals ignores the request, so silence has to end somewhere.
  @open_timeout Application.compile_env(:loom, [__MODULE__, :open_timeout], 15_000)

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
    title = Keyword.get(opts, :title)

    state = %{
      id: id,
      pty: nil,
      os_pid: nil,
      node: nil,
      channel: nil,
      # Only for a device: it said the terminal is open / the shell is gone.
      opened: false,
      ended: false,
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

    case Keyword.get(opts, :node) do
      nil -> {:ok, start_local(state, Keyword.get_lazy(opts, :shell, &default_shell/0))}
      node -> {:ok, start_remote(state, node, Keyword.fetch!(opts, :channel))}
    end
  end

  defp start_local(state, shell) do
    %{cols: cols, rows: rows} = state

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

    %{state | pty: pty, os_pid: os_pid}
  end

  # The channel monitors this process too, and tells the device to hang up if
  # it dies; this one watches the channel for the device going away.
  defp start_remote(state, node, channel) do
    Process.monitor(channel)

    send(
      channel,
      {:node_send, self(), state.id, "pty_open", %{"cols" => state.cols, "rows" => state.rows}}
    )

    Process.send_after(self(), :open_timeout, @open_timeout)
    %{state | node: node, channel: channel}
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
  def handle_cast({:input, _pid, _data}, %{ended: true} = state), do: {:noreply, state}

  def handle_cast({:input, pid, data}, state) do
    cond do
      pid == state.driver ->
        write(state, data)
        {:noreply, state}

      reply_only?(data) ->
        {:noreply, state}

      true ->
        write(state, data)
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
  def handle_info({:pty_data, data}, state), do: {:noreply, output(state, data)}

  def handle_info(:pty_exit, state) do
    Logger.info("PTY for session #{state.id} exited, stopping")
    {:stop, :normal, state}
  end

  # ── From the device ──

  def handle_info({:node_reply, _id, "pty_opened", _}, state),
    do: {:noreply, %{state | opened: true}}

  def handle_info({:node_reply, _id, "pty_out", %{"data" => data}}, state) do
    case Base.decode64(data) do
      {:ok, bytes} -> {:noreply, output(state, bytes)}
      :error -> {:noreply, state}
    end
  end

  def handle_info({:node_reply, _id, "pty_exit", _}, state) do
    Logger.info("Terminal #{state.id} on #{state.node}: the shell exited, stopping")
    {:stop, :normal, %{state | ended: true}}
  end

  def handle_info({:node_reply, _id, "error", %{"message" => message}}, state),
    do: {:noreply, finish(state, "#{state.node} could not open a terminal: #{message}")}

  def handle_info(:open_timeout, %{opened: false, ended: false} = state) do
    {:noreply,
     finish(
       state,
       "#{state.node} did not open a terminal. Its loom-node may predate terminals: " <>
         "reinstall it from Devices."
     )}
  end

  def handle_info(:open_timeout, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{channel: pid} = state) do
    state = %{state | channel: nil}

    if state.ended,
      do: {:noreply, state},
      else:
        {:noreply,
         finish(state, "#{state.node} disconnected. Close this terminal and open a new one.")}
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
    # Whoever is watching: the shell exited, or the terminal was closed from
    # another device. Their column drops it rather than show a dead screen.
    for {pid, _} <- state.clients, do: send(pid, :pty_closed)

    # On a device: hang up there. The channel would also notice this process
    # gone, but only once it is.
    if state.channel && !state.ended, do: send(state.channel, {:node_cancel, state.id})

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
    if state.pty && Process.alive?(state.pty) do
      if state.os_pid && state.os_pid > 1 do
        System.cmd("pkill", ["-KILL", "-s", "#{state.os_pid}"], stderr_to_stdout: true)
        # `--` is required: procps-ng 4.0.4 `kill -KILL -12993` reads only the
        # first digit of the group and sends kill(-1, SIGKILL), taking down
        # every process this user owns, Loom included.
        System.cmd("kill", ["-KILL", "--", "-#{state.os_pid}"], stderr_to_stdout: true)
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
        resize_pty(state, cols, rows)
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

  defp write(%{pty: pty}, data) when pty != nil, do: ExPTY.write(pty, data)

  defp write(%{channel: channel} = state, data) when channel != nil,
    do: send(channel, {:node_send, self(), state.id, "pty_in", %{"data" => Base.encode64(data)}})

  defp write(_state, _data), do: :ok

  defp resize_pty(%{ended: true}, _cols, _rows), do: :ok
  defp resize_pty(%{pty: pty}, cols, rows) when pty != nil, do: ExPTY.resize(pty, cols, rows)

  defp resize_pty(%{channel: channel} = state, cols, rows) when channel != nil,
    do:
      send(
        channel,
        {:node_send, self(), state.id, "pty_resize", %{"cols" => cols, "rows" => rows}}
      )

  defp resize_pty(_state, _cols, _rows), do: :ok

  defp output(state, data) do
    case Loom.Terminal.Sgr.transform(data) do
      "" ->
        state

      output ->
        for {pid, _} <- state.clients, do: send(pid, {:pty_output, output})
        append_buffer(state, output)
    end
  end

  # A device terminal that can no longer run: say why, dimmed, on its own line,
  # and take no more input.
  defp finish(state, message) do
    %{output(state, "\r\n\e[2m[#{message}]\e[0m\r\n") | ended: true}
  end

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
      rows: state.rows,
      node: state.node
    }
  end

  # Read when a terminal opens, not when this module compiles: a module
  # attribute would bake in the `SHELL` of whoever ran `mix release`.
  defp default_shell, do: System.get_env("SHELL") || "/bin/zsh"
end
