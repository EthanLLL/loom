defmodule Loom.Agent.Codex.Server do
  @moduledoc """
  The single `codex app-server` process, shared by every codex session.

  Unlike Claude Code, Codex is a stateful server: one process holds any number of
  threads, addressed by `threadId`. Measured: two threads started in one
  app-server ran turns concurrently and each recalled only its own context, so
  there is no reason to pay for a process per session.

  This GenServer owns the port and does three things:

    * **Request/response correlation.** JSON-RPC ids are a monotonic counter; the
      caller's `from` waits in `pending` until the matching response arrives.
    * **Demultiplexing.** Notifications carry a `threadId`; they are forwarded to
      whichever session process claimed that thread.
    * **Answering server→client requests.** Under automode these should not
      happen, but an unanswered JSON-RPC request stalls the turn forever, so
      anything unexpected is declined rather than ignored.

  ## It stays up, and it heals itself rather than crashing

  Started eagerly with loom and expected to outlive every individual session.
  The app-server is respawned **inside** this process, with backoff, instead of
  by letting the GenServer die and having a supervisor restart it. Two reasons:

    * A `codex` that fails immediately — missing binary, expired login, bad
      config — would otherwise crash-loop and, being a permanent child, take the
      whole application down with it. Here it degrades to `port: nil`: codex
      sessions get a clear error, the rest of loom boots and runs.
    * Restarting is not transparent. The new app-server knows nothing of the old
      threads, so owners have to be told to reattach. That notification is state
      this process has and a supervisor restart would throw away.

  ## Sharing means a shared failure domain

  When the app-server dies, every codex session loses its turn at once, and each
  thread is left holding a writer lock that an ungraceful exit does not release.
  So every owner is sent `{:codex_down, thread_id}` — without it a session waits
  forever for a turn that nobody is running any more — and the locks are cleared
  before the next attach.

  ## Why it does not hold session state

  Only `threads` (thread id to the session pid that owns it) lives here, and only
  so notifications can be routed. Everything else — the conversation, the queue,
  the transcript — belongs to the session, so losing this process costs nothing
  that is not on disk.
  """

  use GenServer

  require Logger

  alias Loom.Agent.Jsonl

  @call_timeout 60_000
  # thread/start spawns MCP servers before replying; measured at ~1.7 s here,
  # but a cold machine with several servers configured can be far slower.
  @start_timeout 120_000

  # ── API ───────────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Whether the app-server is up right now.

  A session that cannot start a thread wants to say *why*, and "the app-server is
  not running" is a different problem from "that thread is locked".
  """
  def available?, do: GenServer.call(__MODULE__, :available?, 5_000)

  @doc """
  Open a new thread and claim it for the calling process.

  `developer_instructions` is where loom's own context goes — it is the slot the
  backend offers for what we used to assemble by hand.
  """
  def start_thread(opts \\ []) do
    GenServer.call(__MODULE__, {:start_thread, self(), opts}, @start_timeout)
  end

  @doc """
  Reattach to an existing thread and claim it.

  Clears a stale writer lock belonging to this thread first: Codex enforces one
  writer per thread with a lock file that an ungraceful kill leaves behind, and
  a session that cannot reopen its own conversation is unrecoverable otherwise.
  """
  def resume_thread(thread_id, opts \\ []) do
    GenServer.call(__MODULE__, {:resume_thread, self(), thread_id, opts}, @start_timeout)
  end

  @doc "Start a turn. Returns the turn id, which `interrupt/2` needs."
  def start_turn(thread_id, text, opts \\ []) do
    GenServer.call(__MODULE__, {:start_turn, thread_id, text, opts}, @call_timeout)
  end

  @doc """
  Inject a message into a running turn.

  `turn_id` is `expectedTurnId` upstream and is what makes this race-safe: if
  the turn has already finished, the call fails instead of the message being
  delivered to whatever runs next.
  """
  def steer(thread_id, turn_id, text) do
    GenServer.call(__MODULE__, {:steer, thread_id, turn_id, text}, @call_timeout)
  end

  @doc "Abort a running turn."
  def interrupt(thread_id, turn_id) do
    GenServer.call(__MODULE__, {:interrupt, thread_id, turn_id}, @call_timeout)
  end

  @doc "Give up ownership of a thread, releasing its writer lock."
  def release(thread_id), do: GenServer.cast(__MODULE__, {:release, thread_id})

  @doc false
  def request(method, params, timeout \\ @call_timeout) do
    GenServer.call(__MODULE__, {:request, method, params}, timeout)
  end

  # ── Server ────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      port: nil,
      next_id: 1,
      pending: %{},
      threads: %{},
      monitors: %{},
      buffer: "",
      codex_home: nil,
      backoff: 0,
      exe: opts[:exe] || Application.get_env(:loom, Loom.Agent, [])[:codex_cli] || "codex"
    }

    if opts[:spawn] == false do
      # Tests drive the protocol directly; spawning a real app-server would make
      # every one of them slow and dependent on a working codex login.
      {:ok, state}
    else
      {:ok, state, {:continue, :boot}}
    end
  end

  @impl GenServer
  def handle_continue(:boot, state), do: {:noreply, boot(state)}

  defp boot(state) do
    case spawn_port(state.exe) do
      {:ok, port} ->
        # Nobody waits on the handshake; its one useful output is `codexHome`,
        # which tells us where the writer locks live. Better to read it than to
        # assume `~/.codex`.
        %{state | port: port, backoff: 0}
        |> send_request("initialize", client_info(), :initialized)

      {:error, reason} ->
        # Not fatal on purpose: loom runs fine without codex, and only sessions
        # bound to it should fail. See the moduledoc.
        Logger.error("Codex.Server cannot start `#{state.exe}`: #{inspect(reason)}")
        schedule_retry(state)
    end
  end

  # Backoff doubles to a ceiling. A machine with no `codex` installed should not
  # spend the rest of its uptime trying to spawn one every second.
  @backoff_start_ms 1_000
  @backoff_max_ms 60_000

  defp schedule_retry(state) do
    delay = min(max(state.backoff * 2, @backoff_start_ms), @backoff_max_ms)
    Process.send_after(self(), :retry_boot, delay)
    %{state | port: nil, backoff: delay}
  end

  defp spawn_port(exe) do
    case System.find_executable(exe) do
      nil ->
        {:error, "not found on PATH"}

      path ->
        {:ok,
         Port.open({:spawn_executable, path}, [
           :binary,
           :exit_status,
           :use_stdio,
           :hide,
           args: ["app-server"]
         ])}
    end
  end

  defp client_info do
    version = Application.spec(:loom, :vsn) |> to_string()
    %{"clientInfo" => %{"name" => "loom", "version" => version}}
  end

  @impl GenServer
  def handle_call(:available?, _from, state), do: {:reply, state.port != nil, state}

  # Nothing can be sent while the app-server is down or being respawned. Saying
  # so immediately beats writing to a dead port or letting the caller time out.
  def handle_call(_request, _from, %{port: nil} = state) do
    {:reply, {:error, :server_down}, state}
  end

  def handle_call({:start_thread, owner, opts}, from, state) do
    params =
      %{
        "cwd" => opts[:cwd] || System.user_home!(),
        "sandbox" => "danger-full-access",
        "approvalPolicy" => "never"
      }
      |> maybe_put("developerInstructions", opts[:developer_instructions])
      |> maybe_put("model", opts[:model])

    {:noreply, send_request(state, "thread/start", params, {:claim, from, owner})}
  end

  def handle_call({:resume_thread, owner, thread_id, opts}, from, state) do
    params =
      %{"threadId" => thread_id, "excludeTurns" => true}
      |> maybe_put("developerInstructions", opts[:developer_instructions])

    {:noreply,
     send_request(state, "thread/resume", params, {:claim_resume, from, owner, thread_id})}
  end

  def handle_call({:start_turn, thread_id, text, opts}, from, state) do
    params =
      %{
        "threadId" => thread_id,
        "input" => [%{"type" => "text", "text" => text}]
      }
      |> maybe_put("model", opts[:model])
      |> maybe_put("effort", opts[:effort])

    {:noreply, send_request(state, "turn/start", params, {:turn, from})}
  end

  def handle_call({:steer, thread_id, turn_id, text}, from, state) do
    params = %{
      "threadId" => thread_id,
      "expectedTurnId" => turn_id,
      "input" => [%{"type" => "text", "text" => text}]
    }

    {:noreply, send_request(state, "turn/steer", params, {:reply, from})}
  end

  def handle_call({:interrupt, thread_id, turn_id}, from, state) do
    params = %{"threadId" => thread_id, "turnId" => turn_id}
    {:noreply, send_request(state, "turn/interrupt", params, {:reply, from})}
  end

  def handle_call({:request, method, params}, from, state) do
    {:noreply, send_request(state, method, params, {:reply, from})}
  end

  @impl GenServer
  def handle_cast({:release, thread_id}, state) do
    {:noreply, forget_thread(state, thread_id)}
  end

  @impl GenServer
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    {lines, buffer} = Jsonl.split(state.buffer <> chunk)
    {:noreply, Enum.reduce(lines, %{state | buffer: buffer}, &handle_line/2)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    # Every in-flight caller has to be told, or they all sit on a 60 s timeout.
    for {_id, tag} <- state.pending, do: fail(tag, :server_down)

    Logger.error("Codex.Server: app-server exited with status #{status}; respawning")

    # Every thread owner has to be told too, or a session waits forever for a
    # turn nobody is running any more. They must reattach: the next app-server
    # knows nothing about these threads.
    for {thread_id, owner} <- state.threads do
      release_lock(state, thread_id)
      send(owner, {:codex_down, thread_id})
    end

    for {_owner, ref} <- state.monitors, do: Process.demonitor(ref, [:flush])

    state = %{state | pending: %{}, threads: %{}, monitors: %{}, buffer: ""}
    {:noreply, schedule_retry(state)}
  end

  def handle_info(:retry_boot, %{port: nil} = state), do: {:noreply, boot(state)}
  def handle_info(:retry_boot, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # A session died. Drop its threads so the writer lock is released and the
    # next resume is not refused by a lock whose owner no longer exists.
    state.threads
    |> Enum.filter(fn {_id, owner} -> owner == pid end)
    |> Enum.reduce(state, fn {id, _}, acc -> forget_thread(acc, id) end)
    |> then(&{:noreply, &1})
  end

  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{port: port}) when is_port(port) do
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Wire ──────────────────────────────────────────────────────────────────

  defp send_request(state, method, params, tag) do
    id = state.next_id
    Port.command(state.port, Jsonl.line(%{"id" => id, "method" => method, "params" => params}))

    pending = if tag, do: Map.put(state.pending, id, tag), else: state.pending
    %{state | next_id: id + 1, pending: pending}
  end

  defp send_result(state, id, result) do
    Port.command(state.port, Jsonl.line(%{"id" => id, "result" => result}))
    state
  end

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, message} -> dispatch(message, state)
      {:error, _} -> log_unparseable(line, state)
    end
  end

  defp log_unparseable(line, state) do
    Logger.warning("Codex.Server: unparseable line: #{String.slice(line, 0, 200)}")
    state
  end

  # A response to something we asked.
  defp dispatch(%{"id" => id} = message, state) when not is_map_key(message, "method") do
    {tag, pending} = Map.pop(state.pending, id)
    state = %{state | pending: pending}
    outcome = if error = message["error"], do: {:error, error}, else: {:ok, message["result"]}
    resolve(tag, outcome, state)
  end

  # A request from the server. Must be answered or the turn stalls.
  defp dispatch(%{"id" => id, "method" => method} = message, state) do
    Logger.warning("Codex.Server: declining unexpected server request #{method}")
    send_result(state, id, decline(method, message))
  end

  # A notification.
  defp dispatch(%{"method" => _method} = message, state), do: route(message, state)

  defp dispatch(_message, state), do: state

  # Used when the app-server dies: every pending caller gets the same answer
  # regardless of what it was waiting for.
  defp fail({:reply, from}, reason), do: GenServer.reply(from, {:error, reason})
  defp fail({:turn, from}, reason), do: GenServer.reply(from, {:error, reason})
  defp fail({:claim, from, _owner}, reason), do: GenServer.reply(from, {:error, reason})

  defp fail({:claim_resume, from, _owner, _id}, reason),
    do: GenServer.reply(from, {:error, reason})

  defp fail({:claim_retry, from, _owner, _id}, reason),
    do: GenServer.reply(from, {:error, reason})

  defp fail(_tag, _reason), do: :ok

  defp resolve(nil, _outcome, state), do: state

  defp resolve(:initialized, {:ok, result}, state) do
    %{state | codex_home: result["codexHome"]}
  end

  defp resolve(:initialized, {:error, error}, state) do
    Logger.error("Codex.Server initialize failed: #{inspect(error)}")
    state
  end

  defp resolve({:reply, from}, outcome, state) do
    GenServer.reply(from, outcome)
    state
  end

  defp resolve({:turn, from}, {:ok, result}, state) do
    GenServer.reply(from, {:ok, get_in(result, ["turn", "id"])})
    state
  end

  defp resolve({:turn, from}, {:error, error}, state) do
    GenServer.reply(from, {:error, message_of(error)})
    state
  end

  defp resolve({:claim, from, owner}, {:ok, result}, state) do
    thread_id = get_in(result, ["thread", "id"])
    GenServer.reply(from, {:ok, thread_id})
    claim(state, thread_id, owner)
  end

  defp resolve({:claim, from, _owner}, {:error, error}, state) do
    GenServer.reply(from, {:error, message_of(error)})
    state
  end

  defp resolve({:claim_resume, from, owner, thread_id}, {:ok, _result}, state) do
    GenServer.reply(from, {:ok, thread_id})
    claim(state, thread_id, owner)
  end

  defp resolve({:claim_resume, from, owner, thread_id}, {:error, error}, state) do
    reason = message_of(error)

    if locked?(reason) do
      # The lock is ours: this session recorded this thread id, so whoever holds
      # it is a previous incarnation of us that did not exit cleanly. Clearing
      # it is the only way back into our own conversation.
      Logger.warning("Codex.Server: clearing stale writer lock for #{thread_id}")
      release_lock(state, thread_id)

      params = %{"threadId" => thread_id, "excludeTurns" => true}
      send_request(state, "thread/resume", params, {:claim_retry, from, owner, thread_id})
    else
      GenServer.reply(from, {:error, reason})
      state
    end
  end

  defp resolve({:claim_retry, from, owner, thread_id}, {:ok, _result}, state) do
    GenServer.reply(from, {:ok, thread_id})
    claim(state, thread_id, owner)
  end

  defp resolve({:claim_retry, from, _owner, _thread_id}, {:error, error}, state) do
    # Cleared the lock and still refused: stop here rather than retrying
    # forever. The session reports itself unusable, which is honest.
    GenServer.reply(from, {:error, message_of(error)})
    state
  end

  defp locked?(reason) when is_binary(reason), do: reason =~ "active writer"
  defp locked?(_reason), do: false

  defp message_of(%{"message" => message}), do: message
  defp message_of(other), do: inspect(other)

  # ── Threads ───────────────────────────────────────────────────────────────

  defp claim(state, nil, _owner), do: state

  defp claim(state, thread_id, owner) do
    monitors =
      if Map.has_key?(state.monitors, owner) do
        state.monitors
      else
        Map.put(state.monitors, owner, Process.monitor(owner))
      end

    %{state | threads: Map.put(state.threads, thread_id, owner), monitors: monitors}
  end

  defp forget_thread(state, thread_id) do
    {owner, threads} = Map.pop(state.threads, thread_id)
    release_lock(state, thread_id)

    monitors =
      if owner && not Enum.any?(threads, fn {_id, o} -> o == owner end) do
        {ref, rest} = Map.pop(state.monitors, owner)
        if ref, do: Process.demonitor(ref, [:flush])
        rest
      else
        state.monitors
      end

    %{state | threads: threads, monitors: monitors}
  end

  # Notifications are addressed by thread, and only the session that claimed
  # that thread hears them. A notification for a thread nobody owns is dropped:
  # that is a thread this node is not driving.
  defp route(%{"params" => %{"threadId" => thread_id}} = message, state) do
    case Map.fetch(state.threads, thread_id) do
      {:ok, owner} -> send(owner, {:codex, thread_id, message})
      :error -> :ok
    end

    state
  end

  defp route(_message, state), do: state

  # ── Writer locks ──────────────────────────────────────────────────────────

  # Delete a thread's writer lock file.
  #
  # Measured: after a SIGKILL, `thread/resume` keeps reporting `-32600 already
  # has an active writer`, and the empty lock file under
  # `<codex_home>/thread-writer-locks/` is what holds it — killing every codex
  # process does not release it. Removing the file makes resume succeed at once.
  #
  # Only safe because loom is single-tenant and single-instance: a lock on a
  # thread recorded in our own `meta.json` can only be ours. Two loom instances
  # on one machine would have to rethink this.
  defp release_lock(state, thread_id) when is_binary(thread_id) do
    path = Path.join([codex_home(state), "thread-writer-locks", thread_id <> ".lock"])
    _ = File.rm(path)
    :ok
  end

  defp release_lock(_state, _thread_id), do: :ok

  defp codex_home(%{codex_home: home}) when is_binary(home), do: home

  defp codex_home(_state) do
    System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex")
  end

  # ── Server requests we refuse ─────────────────────────────────────────────

  # Approvals cannot happen under `approvalPolicy: "never"`, but an
  # unanswered JSON-RPC request stalls the turn with no error anywhere, which is
  # worse than a decline. See docs/backends.md §7.
  defp decline("item/commandExecution/requestApproval", _m), do: %{"decision" => "decline"}
  defp decline("item/fileChange/requestApproval", _m), do: %{"decision" => "decline"}
  defp decline("item/permissions/requestApproval", _m), do: %{"decision" => "decline"}
  defp decline("item/tool/requestUserInput", _m), do: %{"response" => nil}
  defp decline(_method, _m), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
