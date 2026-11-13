defmodule Loom.Agent.Backend.Kiro do
  @moduledoc """
  Kiro as the engine: one `kiro-cli acp` process per session, spoken to in the
  Agent Client Protocol (newline-delimited JSON-RPC 2.0) over stdin/stdout, and
  let go when the session idles.

  The process model is Claude Code's, the wire is Codex's. See
  `docs/backends.md` §9 for the measurements behind each choice below
  (kiro-cli 3.2.0, its default v3 engine).

  ## One process per session

  `kiro-cli acp` is a Rust relay in front of a Node engine (~580 MB together,
  plus whatever MCP servers it starts). One process can hold several ACP
  sessions, but `session/load` reattaches a conversation in about 0.9 s from
  `~/.kiro/sessions`, across processes. So a session gets its own process,
  started on the first turn and killed by `release/1` once idle, exactly like
  Claude Code, and one failing Kiro cannot take the others with it.

  ## The handshake is asynchronous

  A spawn has to say `initialize`, then `session/new` (or `session/load`), and
  only then `session/prompt`. The session process must not block for that, so
  the handle carries a phase and the replies are consumed in `decode/2`:

      :initializing ─init reply→ :opening ─new/load reply→ :ready

  The prompt typed meanwhile waits in `pending`. `session/load` replays the
  whole conversation as `session/update` notifications before it replies;
  everything before `:ready` is dropped, or the transcript would grow a copy of
  the past on every respawn.

  ## Loom's instructions are a Kiro agent

  ACP has no slot for an appended system prompt, but a Kiro agent is one: a
  markdown file in `~/.kiro/agents/` whose body is added to Kiro's own prompt
  and whose frontmatter grants tools and permissions. Every session gets its
  own, `loom-<session id>.md`, written before each spawn (the instructions
  name the session, and are given again at every spawn as for Claude Code)
  and removed by `stop/1`. The engine lists agents as ACP modes, so it is
  selected with the standard `session/set_mode` after every new/load
  (measured on 3.3.0: Kiro kept its identity and every tool, knew what the
  file said, and still did after a `session/load` in a new process).

  ## Model

  The composer's model is the session config option `model`
  (`session/set_config_option`), set after every new/load and again before a
  turn when it changed; `kiro-cli acp --model` would select the v2 engine.
  `models/0` asks `kiro-cli chat --list-models` and keeps the answer a while,
  since it takes a couple of seconds.

  ## Steering and leftovers

  `_session/steer {message, messageId}` queues a message that the engine
  injects at its next boundary, inside the running turn (`steering_injected`).
  Measured even for a pure text answer: it kept writing and answered the steer
  in the same turn. A steer the turn ended without injecting would be lost, so
  anything still pending when `session/prompt` replies is sent as the next
  prompt instead of ending the turn.

  ## Interrupt

  `session/cancel` is a notification. The prompt it cancels replies with
  `stopReason: "cancelled"`, which is swallowed: the session reports the stop
  itself. A new `session/prompt` while one is running *also* cancels it, which
  is why `steer/2` never falls back to that.

  ## Permissions

  `--trust-all-tools` silently selects the old v2 engine. On v3 the agent's
  own `permissions` (`capability: all, effect: allow`) approve every tool
  call without touching the user's Kiro config (measured: no
  `session/request_permission` at all). One that arrives anyway is answered with the allow-once option; a question
  for the user (`_kiro/userInput`) is answered that nobody is there to ask.
  Anything else the engine asks is answered with an error, never ignored: an
  unanswered request hangs the turn.
  """

  @behaviour Loom.Agent.Backend

  require Logger

  alias Loom.Agent.Backend
  alias Loom.Agent.Backend.ClaudeCode
  alias Loom.Agent.Jsonl

  @protocol_version 1

  # After `session/cancel`, how long the prompt gets to reply before the
  # process is killed: one that ignores a cancel is not trusted with more.
  @cancel_grace_ms 10_000
  # After `summarization_failed` the engine may never reply to the prompt
  # so the turn is failed after this much silence rather than left hanging.
  @compaction_failed_ms 60_000

  # What Kiro is told for `_kiro/userInput`: Loom has no question UI.
  @no_user_input "The user is not available to answer questions mid-turn. " <>
                   "Use your best judgement, say what you assumed, and continue."

  # Context windows Kiro's models come in; see `context/2`.
  @windows [128_000, 200_000, 256_000, 400_000, 1_000_000, 2_000_000]
  @default_window 1_000_000

  # How long the model list is kept: `kiro-cli chat --list-models` takes ~2.5 s.
  @models_ttl_ms :timer.minutes(10)

  @impl Backend
  def start(loom_id, meta), do: {:ok, new(loom_id, nil, meta)}

  @impl Backend
  def resume(loom_id, meta) do
    # A session restored before its first turn has no Kiro session yet: the id
    # is only minted by `session/new`. It simply opens one on its first turn.
    {:ok, new(loom_id, Backend.meta_get(meta, :kiro_session_id), meta)}
  end

  defp new(loom_id, session_id, meta) do
    %{
      loom_id: loom_id,
      session_id: session_id,
      cwd: Backend.meta_get(meta, :kiro_cwd) || default_cwd(),
      instructions: Backend.meta_get(meta, :instructions),
      port: nil,
      os_pid: nil,
      buffer: "",
      phase: nil,
      next_id: 1,
      # Request id → what its reply means.
      requests: %{},
      # The prompt waiting for the handshake: `{:prompt, text}` or `:compact`.
      pending: nil,
      # Id of the `session/prompt` (or compaction) in flight, if any.
      prompt_id: nil,
      # Whether this prompt's turn has been reported as running yet.
      announced?: false,
      # Steers sent and not yet injected, oldest first: `{message_id, text}`.
      steers: [],
      interrupted?: false,
      # The reason a summarisation failed during this prompt, if one did.
      compaction_error: nil,
      # The composer's choice (nil: Kiro's default), and what the live
      # process was last told.
      model: Backend.meta_get(meta, :model),
      live_model: nil,
      # The block being streamed: `%{id, type, text}`.
      block: nil,
      tools: %{},
      context_tokens: 0,
      context_window: nil
    }
  end

  # ── Turns ─────────────────────────────────────────────────────────────────

  @impl Backend
  def run_turn(handle, text) when is_binary(text) do
    work = if String.trim(text) == "/compact", do: :compact, else: {:prompt, text}
    handle = %{handle | interrupted?: false, steers: [], tools: %{}}

    case handle do
      %{phase: :ready} = handle ->
        if alive?(handle) do
          {:ok, handle |> apply_model() |> send_work(work)}
        else
          spawn_process(%{handle | port: nil, os_pid: nil}, work)
        end

      %{port: port} = handle when is_port(port) ->
        # Still booting: the new prompt replaces whatever an interrupt dropped.
        {:ok, %{handle | pending: work}}

      handle ->
        spawn_process(handle, work)
    end
  end

  @impl Backend
  def steer(%{phase: :ready, prompt_id: id} = handle, text) when is_integer(id) do
    message_id = "loom-steer-" <> random_id()

    handle =
      request(
        handle,
        "_session/steer",
        %{
          "sessionId" => handle.session_id,
          "message" => text,
          "messageId" => message_id
        },
        {:steer, message_id}
      )

    {:ok, %{handle | steers: handle.steers ++ [{message_id, text}]}}
  end

  # Typed while the process was still booting: it goes out with the prompt.
  def steer(%{pending: {:prompt, prompt}} = handle, text) do
    {:ok, %{handle | pending: {:prompt, prompt <> "\n\n" <> text}}}
  end

  def steer(_handle, _text), do: {:error, "no running kiro turn to steer"}

  @impl Backend
  def interrupt(%{phase: :ready, prompt_id: id} = handle) when is_integer(id) do
    notify(handle, "session/cancel", %{"sessionId" => handle.session_id})
    Process.send_after(self(), {:kiro_timer, handle.port, :cancel, id}, @cancel_grace_ms)
    {:ok, %{handle | interrupted?: true}}
  end

  # Stopped before the prompt went out: it never will.
  def interrupt(handle), do: {:ok, %{handle | pending: nil, interrupted?: true}}

  @impl Backend
  def release(%{port: nil} = handle), do: {:ok, handle}
  def release(handle), do: {:ok, teardown(handle)}

  @impl Backend
  def persist(handle),
    do: %{kiro_session_id: handle.session_id, kiro_cwd: handle.cwd, model: handle.model}

  @impl Backend
  def stop(handle) do
    teardown(handle)
    if handle.loom_id, do: File.rm(agent_path(handle.loom_id))
    :ok
  end

  @impl Backend
  def set_model(handle, model), do: {:ok, %{handle | model: model}}

  @impl Backend
  def models do
    case :persistent_term.get({__MODULE__, :models}, nil) do
      {at, models} when is_integer(at) ->
        if System.monotonic_time(:millisecond) - at < @models_ttl_ms,
          do: models,
          else: fetch_models()

      _ ->
        fetch_models()
    end
  end

  # Kiro marks no default in JSON; `auto` is it (the plain list stars it).
  defp fetch_models do
    with {:ok, exe} <- executable(),
         {out, 0} <- run_list_models(exe),
         {:ok, %{"models" => list}} when is_list(list) <- Jason.decode(out) do
      models =
        for %{"model_id" => id} = m <- list, is_binary(id) do
          %{id: id, label: m["model_name"] || id, default: id == "auto"}
        end

      :persistent_term.put({__MODULE__, :models}, {System.monotonic_time(:millisecond), models})
      models
    else
      other ->
        Logger.warning("Kiro: cannot list models: #{inspect(other) |> String.slice(0, 300)}")
        []
    end
  end

  defp run_list_models(exe) do
    task =
      Task.async(fn ->
        System.cmd(exe, ["chat", "--list-models", "--format", "json"],
          env: Loom.ChildEnv.cmd_env(),
          stderr_to_stdout: false
        )
      end)

    case Task.yield(task, 15_000) || Task.shutdown(task) do
      {:ok, result} -> result
      _ -> :timeout
    end
  end

  # ── Process ───────────────────────────────────────────────────────────────

  defp spawn_process(handle, work) do
    with {:ok, exe} <- executable(),
         :ok <- write_agent(handle) do
      port =
        Port.open({:spawn_executable, exe}, [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          # Explicit, so a release that changes the default engine cannot
          # silently switch this adapter onto one it was not written for.
          args: ["acp", "--agent-engine", "v3", "--auth-method", "cli"],
          cd: handle.cwd,
          env: Loom.ChildEnv.port_env(System.get_env())
        ])

      handle = %{
        handle
        | port: port,
          os_pid: os_pid(port),
          buffer: "",
          phase: :initializing,
          requests: %{},
          pending: work,
          prompt_id: nil,
          block: nil,
          live_model: nil
      }

      {:ok,
       request(
         handle,
         "initialize",
         %{
           "protocolVersion" => @protocol_version,
           "clientCapabilities" => %{
             "fs" => %{"readTextFile" => false, "writeTextFile" => false},
             "terminal" => false,
             # Without it a question for the user arrives as a permission
             # request, and allow-once reaches the model as "yes".
             "_meta" => %{"kiro" => %{"userInput" => true}}
           },
           "clientInfo" => %{"name" => "loom", "version" => version()}
         },
         :initialize
       )}
    end
  end

  # After every new/load: the session's own agent (Loom's instructions and
  # permissions), then the composer's model if one is picked. Sent without
  # waiting; the engine answers requests in order (measured).
  defp select_agent(handle) do
    handle
    |> request(
      "session/set_mode",
      %{"sessionId" => handle.session_id, "modeId" => agent_name(handle.loom_id)},
      :set_mode
    )
    |> apply_model()
  end

  # `kiro-cli acp --model` is a v2-only flag and silently selects the v2
  # engine, and v3 ignores Kiro's own `chat.defaultModel` (measured): the
  # model is a session config option. nil goes back to Kiro's default, `auto`.
  defp apply_model(%{model: model, live_model: model} = handle) when model != nil, do: handle
  defp apply_model(%{model: nil, live_model: nil} = handle), do: handle

  defp apply_model(handle) do
    handle
    |> request(
      "session/set_config_option",
      %{
        "sessionId" => handle.session_id,
        "configId" => "model",
        "value" => handle.model || "auto"
      },
      :set_model
    )
    |> Map.put(:live_model, handle.model)
  end

  # ── The session's Kiro agent ──────────────────────────────────────────────

  @doc false
  def agent_path(loom_id), do: Path.join(agents_dir(), agent_name(loom_id) <> ".md")

  defp agent_name(loom_id), do: "loom-" <> to_string(loom_id)

  defp agents_dir do
    Application.get_env(:loom, Loom.Agent, [])[:kiro_agents_dir] ||
      Path.join(System.user_home!(), ".kiro/agents")
  end

  @doc false
  # Public so a test can read what a session's agent says.
  def agent_file(handle) do
    """
    ---
    name: #{agent_name(handle.loom_id)}
    description: Loom session #{handle.loom_id}; written by Loom at every spawn
    tools: "*"
    includeMcpJson: true
    permissions:
      rules:
        - capability: all
          effect: allow
    ---
    #{handle.instructions || ""}
    """
  end

  defp write_agent(handle) do
    path = agent_path(handle.loom_id)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path <> ".tmp", agent_file(handle)),
         :ok <- File.rename(path <> ".tmp", path) do
      :ok
    else
      {:error, reason} -> {:error, "cannot write Kiro agent #{path}: #{inspect(reason)}"}
    end
  end

  defp alive?(%{port: port}) when is_port(port), do: Port.info(port) != nil
  defp alive?(_handle), do: false

  defp teardown(%{port: nil} = handle), do: handle

  defp teardown(handle) do
    # kiro-cli → node → MCP servers: the same orphaning problem as Claude Code.
    ClaudeCode.kill_tree(handle.os_pid)

    if is_port(handle.port) and Port.info(handle.port) != nil, do: Port.close(handle.port)

    %{handle | port: nil, os_pid: nil, buffer: "", phase: nil, requests: %{}, prompt_id: nil}
  end

  # ── Wire ──────────────────────────────────────────────────────────────────

  defp request(handle, method, params, tag) do
    id = handle.next_id
    write(handle, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    %{handle | next_id: id + 1, requests: Map.put(handle.requests, id, tag)}
  end

  defp notify(handle, method, params) do
    write(handle, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  defp respond(handle, id, outcome) do
    message =
      case outcome do
        {:ok, result} ->
          %{"jsonrpc" => "2.0", "id" => id, "result" => result}

        {:error, code, msg} ->
          %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => msg}}
      end

    write(handle, message)
  end

  defp write(handle, message) do
    # A CLI that exits at once can close the port before the first write; the
    # `exit_status` on its way says why.
    try do
      Port.command(handle.port, Jsonl.line(message))
    rescue
      ArgumentError -> :closed
    end

    handle
  end

  defp send_work(handle, {:prompt, text}) do
    handle =
      request(
        handle,
        "session/prompt",
        %{
          "sessionId" => handle.session_id,
          "prompt" => [%{"type" => "text", "text" => text}],
          # Makes `turn_completion` carry the model's real window.
          "_meta" => %{"kiro" => %{"contextBreakdown" => "summary"}}
        },
        :prompt
      )

    started(handle)
  end

  defp send_work(handle, :compact) do
    handle =
      request(handle, "_kiro/session/compact", %{"sessionId" => handle.session_id}, :prompt)

    started(handle)
  end

  defp started(handle) do
    %{
      handle
      | prompt_id: handle.next_id - 1,
        pending: nil,
        announced?: false,
        compaction_error: nil
    }
  end

  # ── Decoding ──────────────────────────────────────────────────────────────

  @impl Backend
  def decode(%{port: port} = handle, {port, {:data, chunk}}) do
    {lines, buffer} = Jsonl.split(handle.buffer <> chunk)

    {handle, out} =
      Enum.reduce(lines, {%{handle | buffer: buffer}, []}, fn line, {acc, out} ->
        case Jason.decode(line) do
          {:ok, message} ->
            {acc, produced} = dispatch(acc, message)
            {acc, out ++ produced}

          {:error, _} ->
            Logger.warning("Kiro: unparseable output line: #{String.slice(line, 0, 200)}")
            {acc, out}
        end
      end)

    {:ok, handle, out}
  end

  # Died on its own: one we kill is forgotten first and falls to the clause below.
  def decode(%{port: port} = handle, {port, {:exit_status, status}}) do
    {flushed, out} = close_block(handle)
    busy? = flushed.prompt_id != nil or flushed.pending != nil

    handle = %{
      flushed
      | port: nil,
        os_pid: nil,
        phase: nil,
        requests: %{},
        prompt_id: nil,
        pending: nil
    }

    if busy? do
      {:ok, handle,
       out ++
         [
           {:event, :turn_failed,
            %{reason: "kiro-cli exited with status #{status} before finishing the turn"}}
         ]}
    else
      Logger.warning("Kiro: kiro-cli exited with status #{status} between turns")
      {:ok, handle, out}
    end
  end

  def decode(handle, {port, {:exit_status, _status}}) when is_port(port), do: {:ok, handle, []}

  # The cancelled prompt never replied. The session already reported the
  # stop; a process that ignores a cancel is not trusted with the next turn.
  def decode(%{port: port, prompt_id: id} = handle, {:kiro_timer, port, :cancel, id})
      when is_integer(id) do
    Logger.warning(
      "Kiro: no reply #{div(@cancel_grace_ms, 1000)} s after cancel; killing kiro-cli"
    )

    {:ok, %{teardown(handle) | interrupted?: false, steers: []}, []}
  end

  def decode(%{port: port, prompt_id: id} = handle, {:kiro_timer, port, :compaction, id})
      when is_integer(id) do
    notify(handle, "session/cancel", %{"sessionId" => handle.session_id})
    {handle, flushed} = close_block(handle)

    {:ok, %{handle | prompt_id: nil, steers: []},
     flushed ++ [{:event, :turn_failed, %{reason: compaction_reason(handle.compaction_error)}}]}
  end

  # A timer for a prompt that has since ended.
  def decode(handle, {:kiro_timer, _port, _kind, _id}), do: {:ok, handle, []}

  def decode(_handle, _message), do: :ignore

  # A reply to something we asked.
  defp dispatch(handle, %{"id" => id} = message) when not is_map_key(message, "method") do
    {tag, requests} = Map.pop(handle.requests, id)
    handle = %{handle | requests: requests}

    outcome =
      case message do
        %{"error" => error} when not is_nil(error) -> {:error, error}
        _ -> {:ok, message["result"] || %{}}
      end

    reply(handle, tag, id, outcome)
  end

  # A request from the engine. Must be answered or the turn stalls.
  defp dispatch(handle, %{"id" => id, "method" => method} = message) do
    {answer(handle, id, method, message["params"] || %{}), []}
  end

  # A notification. Nothing before `:ready` is live: `session/load` replays the
  # whole history this way.
  defp dispatch(%{phase: :ready} = handle, %{"method" => "session/update", "params" => params}) do
    if params["sessionId"] == handle.session_id and live?(params["update"]) do
      {handle, running} = announce(handle)
      {handle, out} = update(handle, params["update"] || %{})
      {handle, running ++ out}
    else
      {handle, []}
    end
  end

  defp dispatch(handle, _message), do: {handle, []}

  # A replayed frame (`noReplay` should prevent them) or a sub-agent's: a
  # sub-agent's text is not this conversation's, and its tool calls would
  # interleave with the main ones. Its result reaches the main agent as the
  # sub-agent tool's own output.
  defp live?(%{"_meta" => %{"kiro" => kiro}}) when is_map(kiro),
    do: kiro["replay"] != true and is_nil(kiro["agentSubtaskId"])

  defp live?(_update), do: true

  # ── Replies ───────────────────────────────────────────────────────────────

  defp reply(handle, nil, _id, _outcome), do: {handle, []}

  defp reply(handle, :initialize, _id, {:ok, _result}) do
    handle = %{handle | phase: :opening}

    case handle.session_id do
      nil -> {open_new(handle), []}
      id -> {request(handle, "session/load", session_params(handle, id), :load), []}
    end
  end

  defp reply(handle, :initialize, _id, {:error, error}),
    do: boot_failed(handle, "initialize", error)

  defp reply(handle, :new, _id, {:ok, %{"sessionId" => id}}) do
    ready(%{handle | session_id: id})
  end

  defp reply(handle, :new, _id, {:ok, other}), do: boot_failed(handle, "session/new", other)
  defp reply(handle, :new, _id, {:error, error}), do: boot_failed(handle, "session/new", error)

  # A reply without `modes` is not a session the engine can run: treated as
  # a failed load.
  defp reply(handle, :load, id, {:ok, result}) when not is_map_key(result, "modes"),
    do: reply(handle, :load, id, {:error, "the load reply has no modes"})

  defp reply(handle, :load, _id, {:ok, result}) do
    ready(context_from_load(handle, result))
  end

  # A conversation that never ran a prompt was never written, so it cannot be
  # loaded. Nothing in it to lose: open a new one, as Codex's adapter does.
  defp reply(handle, :load, _id, {:error, error}) do
    Logger.warning(
      "Kiro: cannot load session #{handle.session_id} (#{message_of(error)}); opening a new one"
    )

    {open_new(%{handle | session_id: nil}), []}
  end

  defp reply(handle, :prompt, id, outcome) when id == handle.prompt_id do
    {handle, running} = announce(handle)
    {handle, flushed} = close_block(handle)
    handle = %{handle | prompt_id: nil}
    {handle, out} = prompt_done(handle, outcome)
    {handle, running ++ flushed ++ out}
  end

  # The reply to a prompt we already gave up on (cancelled, then replaced).
  defp reply(handle, :prompt, _id, _outcome), do: {handle, []}

  defp reply(handle, {:steer, message_id}, _id, {:error, error}) do
    Logger.warning("Kiro: steer refused: #{message_of(error)}")
    # It was never queued, so do not resend it at the turn's end either; the
    # session will not know, which is the same loss Claude Code risks.
    {%{handle | steers: List.keydelete(handle.steers, message_id, 0)}, []}
  end

  # Kiro names the steer itself (measured: ours with `steer-` in front), and
  # `steering_injected` uses its name.
  defp reply(handle, {:steer, ours}, _id, {:ok, %{"messageId" => theirs}})
       when is_binary(theirs) do
    steers =
      Enum.map(handle.steers, fn
        {^ours, text} -> {theirs, text}
        other -> other
      end)

    {%{handle | steers: steers}, []}
  end

  defp reply(handle, {:steer, _}, _id, {:ok, _}), do: {handle, []}

  defp reply(handle, :set_model, _id, {:error, error}) do
    Logger.warning("Kiro: cannot select model: #{message_of(error)}")
    {handle, []}
  end

  defp reply(handle, :set_model, _id, {:ok, _}), do: {handle, []}

  defp reply(handle, :set_mode, _id, {:error, error}) do
    Logger.warning("Kiro: cannot select the session's agent: #{message_of(error)}")
    {handle, []}
  end

  defp reply(handle, :set_mode, _id, {:ok, _}), do: {handle, []}

  defp open_new(handle), do: request(handle, "session/new", session_params(handle, nil), :new)

  @doc false
  # Public only so a test can see what new/load send.
  def session_params(handle, nil), do: %{"cwd" => handle.cwd, "mcpServers" => []}

  def session_params(handle, id) do
    %{
      "sessionId" => id,
      "cwd" => handle.cwd,
      "mcpServers" => [],
      "_meta" => %{"kiro" => %{"noReplay" => true}}
    }
  end

  defp ready(handle) do
    handle = select_agent(%{handle | phase: :ready})

    case handle.pending do
      nil -> {handle, []}
      work -> handle |> send_work(work) |> announce()
    end
  end

  # The session waits in `:starting` until told the turn is under way. A warm
  # process gives no handshake to say so, so the first word from the engine
  # about this prompt does.
  defp announce(%{prompt_id: id, announced?: false} = handle) when is_integer(id) do
    {%{handle | announced?: true},
     [{:event, :status, %{status: :running, backend_ref: handle.session_id}}]}
  end

  defp announce(handle), do: {handle, []}

  defp boot_failed(handle, step, error) do
    handle = teardown(%{handle | pending: nil})
    {handle, [{:event, :turn_failed, %{reason: "kiro #{step} failed: #{message_of(error)}"}}]}
  end

  defp prompt_done(%{interrupted?: true} = handle, _outcome) do
    # We asked for it; the session has already reported the stop.
    {%{handle | interrupted?: false, steers: []}, []}
  end

  defp prompt_done(handle, {:error, error}) do
    {%{handle | steers: []}, [{:event, :turn_failed, %{reason: message_of(error)}}]}
  end

  # Steers the turn ended without injecting: they become the next prompt, so
  # the message lands late rather than never. The turn goes on.
  defp prompt_done(%{steers: [_ | _] = steers} = handle, {:ok, _result}) do
    text = Enum.map_join(steers, "\n\n", fn {_id, text} -> text end)
    {send_work(%{handle | steers: []}, {:prompt, text}), []}
  end

  defp prompt_done(handle, {:ok, %{"success" => false}}) do
    {handle, [{:event, :turn_failed, %{reason: compaction_reason(handle.compaction_error)}}]}
  end

  defp prompt_done(handle, {:ok, result}) do
    case result["stopReason"] do
      "cancelled" ->
        {handle, []}

      "refusal" ->
        {handle, [{:event, :turn_failed, %{reason: "the model refused to continue"}}]}

      reason ->
        {handle,
         [
           {:event, :turn_done,
            %{
              stop_reason: reason || "end_turn",
              context_tokens: handle.context_tokens,
              context_window: handle.context_window
            }}
         ]}
    end
  end

  # ── Engine requests ───────────────────────────────────────────────────────

  defp answer(handle, id, "session/request_permission", params) do
    options = params["options"] || []

    choice =
      Enum.find(options, &(&1["kind"] == "allow_once")) ||
        Enum.find(options, &(&1["kind"] == "allow_always"))

    case choice do
      %{"optionId" => option} ->
        respond(
          handle,
          id,
          {:ok, %{"outcome" => %{"outcome" => "selected", "optionId" => option}}}
        )

      nil ->
        Logger.warning("Kiro: permission request with no allow option: #{inspect(options)}")
        respond(handle, id, {:ok, %{"outcome" => %{"outcome" => "cancelled"}}})
    end
  end

  defp answer(handle, id, "_kiro/userInput", params) do
    Logger.info(
      "Kiro asked the user: #{inspect(params["question"])}; answering that nobody is there"
    )

    respond(handle, id, {:ok, %{"action" => "answered", "answer" => @no_user_input}})
  end

  defp answer(handle, id, method, _params) do
    Logger.warning("Kiro: declining unexpected request #{method}")
    respond(handle, id, {:error, -32601, "not supported by loom"})
  end

  # ── Session updates ───────────────────────────────────────────────────────

  defp update(handle, %{"sessionUpdate" => "agent_message_chunk"} = u),
    do: chunk(handle, :text, u)

  defp update(handle, %{"sessionUpdate" => "agent_thought_chunk"} = u),
    do: chunk(handle, :thinking, u)

  defp update(handle, %{"sessionUpdate" => "tool_call"} = u) do
    {handle, flushed} = close_block(handle)
    id = u["toolCallId"]

    if Map.has_key?(handle.tools, id) do
      {handle, out} = tool_progress(handle, u)
      {handle, flushed ++ out}
    else
      name = tool_name(u)
      handle = %{handle | tools: Map.put(handle.tools, id, name)}

      out = [
        {:delta, %{block_id: id, type: :tool_use_start, name: name, id: id}},
        {:event, :tool_use, %{id: id, block_id: id, name: name, input: tool_input(u)}}
      ]

      {handle, out2} = tool_progress(handle, u)
      {handle, flushed ++ out ++ out2}
    end
  end

  defp update(handle, %{"sessionUpdate" => "tool_call_update"} = u), do: tool_progress(handle, u)

  defp update(handle, %{"sessionUpdate" => "session_info_update"} = u) do
    info(handle, get_in(u, ["_meta", "kiro"]) || %{})
  end

  # Plans, mode and command lists, config options, our own message echoed:
  # nothing this UI shows.
  defp update(handle, _update), do: {handle, []}

  defp info(handle, %{"kind" => "context_usage"} = kiro), do: {context(handle, kiro), []}

  defp info(handle, %{"kind" => "steering_injected", "messageId" => id}) do
    {%{handle | steers: List.keydelete(handle.steers, id, 0)}, []}
  end

  # An automatic summarisation at the threshold, or the one `/compact` asked for.
  defp info(handle, %{"kind" => "summarization_completed"} = kiro) do
    if get_in(kiro, ["summarization", "status"]) in [nil, "success"],
      do: {handle, [{:event, :compacted, %{}}]},
      else: {handle, []}
  end

  # A failed summarisation can leave the prompt with no reply at all; see
  # `@compaction_failed_ms`.
  defp info(%{prompt_id: id} = handle, %{"kind" => "summarization_failed"} = kiro) do
    reason = failure_detail(kiro) || "no reason given"
    Logger.warning("Kiro: summarisation failed: #{reason}")

    if is_integer(id),
      do:
        Process.send_after(
          self(),
          {:kiro_timer, handle.port, :compaction, id},
          @compaction_failed_ms
        )

    {%{handle | compaction_error: reason}, []}
  end

  # The real window, when the prompt asked for `contextBreakdown`.
  defp info(handle, %{"kind" => "turn_completion", "contextBreakdown" => breakdown}) do
    case breakdown["window"] do
      %{"sizeTokens" => size} = window when is_integer(size) and size > 0 ->
        pct = window["usagePercentage"]

        tokens =
          if is_number(pct), do: round(size * pct / 100), else: handle.context_tokens

        {%{handle | context_window: size, context_tokens: tokens}, []}

      _ ->
        {handle, []}
    end
  end

  defp info(handle, %{"kind" => "model_fallback"} = kiro) do
    Logger.warning(
      "Kiro: model fallback #{inspect(kiro["from"])} -> #{inspect(kiro["to"])} " <>
        "(#{kiro["trigger"]}, #{kiro["scope"]}): #{kiro["reason"]}"
    )

    {handle, []}
  end

  defp info(handle, _kiro), do: {handle, []}

  defp compaction_reason(nil), do: "kiro could not compact the conversation"
  defp compaction_reason(reason), do: "kiro could not compact the conversation: #{reason}"

  # The most specific of these the engine gave, searched a few levels deep.
  @detail_keys ~w(userFacingSessionErrorMessage reason message error detail)
  @placeholders ["", "error", "failed", "failure", "unknown"]

  defp failure_detail(value, depth \\ 0)
  defp failure_detail(_value, depth) when depth > 6, do: nil

  defp failure_detail(%{} = map, depth) do
    Enum.find_value(@detail_keys, fn key ->
      case map[key] do
        text when is_binary(text) ->
          if String.downcase(String.trim(text)) in @placeholders, do: nil, else: text

        _ ->
          nil
      end
    end) || Enum.find_value(Map.values(map), &failure_detail(&1, depth + 1))
  end

  defp failure_detail(list, depth) when is_list(list),
    do: Enum.find_value(list, &failure_detail(&1, depth + 1))

  defp failure_detail(_value, _depth), do: nil

  # ── Text blocks ───────────────────────────────────────────────────────────

  # ACP chunks carry no block id. Kiro's `_meta.kiro.replayId` names the
  # message a chunk belongs to; a change of kind or of replayId starts a new
  # block, and anything else (a tool call, the end of the turn) closes it.
  defp chunk(handle, type, update) do
    text = get_in(update, ["content", "text"])

    if is_binary(text) do
      key = get_in(update, ["_meta", "kiro", "replayId"])

      {handle, closed} =
        case handle.block do
          %{type: ^type, key: ^key} -> {handle, []}
          nil -> {handle, []}
          _other -> close_block(handle)
        end

      {handle, opened} =
        case handle.block do
          nil ->
            # Random rather than counted: a counter restarts with the process
            # and would reuse ids the transcript already holds.
            id = "kiro." <> random_id()

            {%{handle | block: %{id: id, type: type, key: key, text: ""}},
             [{:delta, %{block_id: id, type: :block_start, block_type: type}}]}

          _ ->
            {handle, []}
        end

      block = handle.block

      {%{handle | block: %{block | text: block.text <> text}},
       closed ++ opened ++ [{:delta, %{block_id: block.id, type: type, chunk: text}}]}
    else
      {handle, []}
    end
  end

  defp close_block(%{block: nil} = handle), do: {handle, []}

  defp close_block(%{block: block} = handle) do
    kind = if block.type == :thinking, do: :thinking, else: :assistant_text

    {%{handle | block: nil},
     [
       {:delta, %{block_id: block.id, type: :block_end}},
       {:event, kind, %{block_id: block.id, text: block.text}}
     ]}
  end

  # ── Tools ─────────────────────────────────────────────────────────────────

  defp tool_progress(handle, u) do
    id = u["toolCallId"]

    case u["status"] do
      status when status in ["completed", "failed"] ->
        name = Map.get(handle.tools, id) || tool_name(u)

        {%{handle | tools: Map.put(handle.tools, id, name)},
         [
           {:event, :tool_result,
            %{
              id: id,
              name: name,
              status: if(status == "failed", do: :error, else: :ok),
              output: tool_output(u)
            }}
         ]}

      _ ->
        # The v2 engine streams a running command's output as content; v3
        # sends only the final result.
        case content_text(u["content"]) do
          "" -> {handle, []}
          text -> {handle, [{:delta, %{block_id: id, type: :tool_output, chunk: text}}]}
        end
    end
  end

  defp tool_name(u) do
    get_in(u, ["_meta", "kiro", "toolName"]) || kind_name(u["kind"]) || u["title"] || "tool"
  end

  defp kind_name("execute"), do: "shell"
  defp kind_name("read"), do: "read"
  defp kind_name("edit"), do: "edit"
  defp kind_name("delete"), do: "delete"
  defp kind_name("move"), do: "move"
  defp kind_name("search"), do: "search"
  defp kind_name("fetch"), do: "fetch"
  defp kind_name(_kind), do: nil

  defp tool_input(u) do
    input = u["rawInput"]

    input =
      if is_map(input), do: Map.drop(input, ["__tool_use_purpose"]), else: %{"input" => input}

    case u["title"] do
      title when is_binary(title) -> Map.put_new(input, "description", title)
      _ -> input
    end
  end

  defp tool_output(u) do
    case content_text(u["content"]) do
      "" -> raw_output(u["rawOutput"])
      text -> text
    end
  end

  defp raw_output(nil), do: ""
  defp raw_output(text) when is_binary(text), do: text
  defp raw_output(%{"message" => message}) when is_binary(message), do: message
  defp raw_output(%{"output" => output}) when is_binary(output), do: output

  defp raw_output(%{"items" => items}) when is_list(items) do
    Enum.map_join(items, "\n", fn
      %{"Json" => %{"stdout" => out} = json} -> out <> (json["stderr"] || "")
      %{"Text" => text} when is_binary(text) -> text
      other -> inspect(other)
    end)
  end

  defp raw_output(other), do: Jason.encode!(other)

  defp content_text(list) when is_list(list) do
    list
    |> Enum.map(fn
      %{"type" => "content", "content" => %{"text" => text}} when is_binary(text) -> text
      %{"type" => "diff", "path" => path} -> "edited #{path}"
      %{"text" => text} when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.join()
  end

  defp content_text(_), do: ""

  # ── Context ───────────────────────────────────────────────────────────────

  # Kiro reports the context as `usagePercentage` of a window it never names.
  # Its breakdown has tokens and a percent per item, but not reliably both
  # (measured: `yourPrompts` at 0 tokens and 3.5 %), and its token sum fell
  # well short of the percentage. So the window is inferred from the item with
  # the most tokens, snapped to a real size, and the context is the percentage
  # of that.
  defp context(handle, kiro) do
    pct = kiro["usagePercentage"] || get_in(kiro, ["contextUsage", "usagePercentage"])
    window = window_of(kiro["breakdown"]) || handle.context_window || @default_window

    if is_number(pct),
      do: %{handle | context_tokens: round(window * pct / 100), context_window: window},
      else: handle
  end

  defp context_from_load(handle, result) do
    case get_in(result, ["_meta", "contextUsage"]) do
      %{} = usage -> context(handle, usage)
      _ -> handle
    end
  end

  defp window_of(%{} = breakdown) do
    breakdown
    |> Map.values()
    |> Enum.filter(fn
      %{"tokens" => tokens, "percent" => percent} ->
        is_integer(tokens) and tokens > 0 and is_number(percent) and percent > 0

      _ ->
        false
    end)
    |> Enum.max_by(& &1["tokens"], fn -> nil end)
    |> case do
      nil -> nil
      %{"tokens" => tokens, "percent" => percent} -> snap(tokens * 100 / percent)
    end
  end

  defp window_of(_breakdown), do: nil

  @doc false
  def snap(estimate), do: Enum.min_by(@windows, &abs(&1 - estimate))

  # ── Misc ──────────────────────────────────────────────────────────────────

  defp message_of(%{"message" => _, "data" => %{"errorType" => type}} = error)
       when is_binary(type) do
    message_of(Map.delete(error, "data")) <> " (#{type})"
  end

  defp message_of(%{"message" => message} = error) do
    case error["data"] do
      %{"message" => detail} when is_binary(detail) -> "#{message}: #{detail}"
      detail when is_binary(detail) -> "#{message}: #{detail}"
      _ -> message
    end
  end

  defp message_of(other) when is_binary(other), do: other
  defp message_of(other), do: inspect(other)

  defp executable do
    configured = Application.get_env(:loom, Loom.Agent, [])[:kiro_cli] || "kiro-cli"

    case System.find_executable(configured) do
      nil -> {:error, "could not find the `#{configured}` executable on PATH"}
      path -> {:ok, path}
    end
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  defp default_cwd do
    Application.get_env(:loom, Loom.Agent, [])[:workspace] || System.user_home!()
  end

  defp version, do: Application.spec(:loom, :vsn) |> to_string()

  defp random_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
