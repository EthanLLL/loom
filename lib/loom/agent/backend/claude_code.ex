defmodule Loom.Agent.Backend.ClaudeCode do
  @moduledoc """
  Claude Code as the engine: one `claude -p` process per turn, nothing at rest.

  ## One process per session, kept warm between turns

  The startup cost is paid **once per session**, not once per turn. Measured on
  one process, writing the second message only after the first turn's `result`
  had arrived:

      turn 1 (cold)   init 4.65 s   first token 9.70 s   done 9.74 s   275 MB
      turn 2          init 0.02 s   first token 1.91 s   done 1.93 s   277 MB
      turn 3          init 0.01 s   first token 1.65 s   done 1.76 s   279 MB

  Turn 3 correctly recalled both earlier answers, so the conversation really is
  live in the process rather than being re-read from disk each time. Memory grows
  about 2 MB per turn, not the hundreds an earlier note had feared.

  Spawning per turn instead would pay ~6 s *every* turn — and pre-spawning the
  next one in the background costs the same resident memory as just keeping this
  one, while churning a 275 MB process for nothing. So: keep it.

  What makes that affordable is `release/1` on an idle timer: 275 MB is the right
  price while someone is working and pure waste once they walk away. The
  conversation survives regardless, in
  `~/.claude/projects/<cwd-slug>/<uuid>.jsonl`, and comes back with `--resume`.

  ## Everything goes over stdin, including steering

  A message written while a turn is running is injected into that turn at the
  next tool-result boundary. Measured: a "stop, do this instead" sent 16 s into a
  five-step shell task arrived alongside step two's output, and the model
  abandoned steps three to five — **one** `result`, not two. With no tool
  boundary left it falls through to the next turn instead.

  So `run_turn/2` and `steer/2` write the same line to the same pipe; the
  difference is only whether a turn is already in flight.

  (`claude -p "<prompt>"` with the prompt in argv waits three seconds for stdin
  before starting — "no stdin data received in 3s" — and would put arbitrary user
  text on a command line. stdin avoids both.)

  stdin is never closed. The process is reclaimed by killing it, not by EOF.

  ## Interrupting asks politely, because killing would burn the warm process

  A `control_request` with subtype `interrupt` ends the turn and leaves the
  process running and usable (measured: it answered `{"still_queued": []}` and
  was still alive 18 s later). Killing would work too — SIGKILL mid-turn leaves
  the conversation perfectly resumable — but it would throw away the warm
  process and make the next turn cold again.

  The cost is that the aborted turn reports itself as
  `result/error_during_execution` with `terminal_reason: "aborted_streaming"`,
  which is not an error at all. `interrupted?` is what lets `decode/2` recognise
  the one we asked for and stay quiet, so the session's own abort event is not
  double-reported as a failure.

  Teardown still has to kill, and killing means the whole tree: `claude` is three
  processes deep and killing the outermost **leaves the other two alive**
  (measured: a 24 MB launcher and a 224 MB runtime orphaned). So `kill_tree/1`
  snapshots descendants with `pgrep -P` *before* killing anything — once the
  parent dies the children are reparented and the relationship is gone.

  ## Which configuration gets loaded

  `--setting-sources user` loads the machine's own Claude Code config — MCP
  servers, hooks, rules — and excludes `project` and `local`. Measured:

      --setting-sources ""     20 tools,  0 MCP, 15,555 prompt tokens
      --setting-sources user   90 tools, 67 MCP, 31,001 prompt tokens

  The MCP servers are the point: web search and everything else loom used to
  implement natively now arrives this way, so paying for them is paying for the
  capability. The prompt is cached after the first turn of a session, so the
  marginal cost of the extra ~15K is a cached read.

  `project` and `local` are excluded because every session runs in the home
  directory: whatever `.claude/settings.local.json` happens to be lying around
  should not change how the agent behaves.

  Two measurements that look tempting and are not:

    * `--strict-mcp-config` cuts the prompt in half, and takes every MCP server
      with it. MCP is the only extension point left now that loom runs no tools
      of its own.
    * `--bare` cuts the prompt to 1,604 tokens, but strips Claude Code's own
      system prompt too and leaves `Bash, Edit, Read`. That throws away what we
      came for.
  """

  @behaviour Loom.Agent.Backend

  require Logger

  alias Loom.Agent.Backend
  alias Loom.Agent.Jsonl

  @base_args [
    "-p",
    "--verbose",
    "--input-format",
    "stream-json",
    "--output-format",
    "stream-json",
    "--include-partial-messages",
    "--setting-sources",
    "user",
    "--permission-mode",
    "bypassPermissions"
  ]

  # Interrupt and teardown both kill; this is how long we give the tree to
  # actually disappear before saying so in the log. Generous because a 224 MB
  # node process can take a moment, and we only read it to warn.
  @reap_grace_ms 2_000

  @impl Backend
  def start(_session_id, meta) do
    {:ok, new(uuid4(), meta)}
  end

  @impl Backend
  def resume(_session_id, meta) do
    case Backend.meta_get(meta, :cc_session_id) do
      id when is_binary(id) ->
        # `--resume <uuid>` locates a conversation across working directories
        # (measured), so there is nothing else to restore.
        {:ok, %{new(id, meta) | first_turn?: false}}

      _ ->
        {:error, "no cc_session_id recorded for this session"}
    end
  end

  defp new(session_id, meta) do
    %{
      session_id: session_id,
      cwd: Backend.meta_get(meta, :cc_cwd) || default_cwd(),
      first_turn?: true,
      port: nil,
      os_pid: nil,
      ref: nil,
      buffer: "",
      tools: %{},
      # Set by interrupt/1 so the `result` that follows is recognised as the one
      # we asked for rather than reported as a failure.
      interrupted?: false,
      next_control_id: 1,
      # Taken from the *last* API call of the turn, which is the only honest
      # measure of how big the conversation now is. See `context/2`.
      context_tokens: 0,
      context_window: nil
    }
  end

  @impl Backend
  def run_turn(handle, text) when is_binary(text) do
    with {:ok, handle} <- ensure_process(handle) do
      write(handle, message_line(text))
      # A fresh `ref` per turn keeps block ids from colliding across turns in
      # one long-lived process.
      {:ok, %{handle | ref: turn_ref(), tools: %{}, interrupted?: false}}
    end
  end

  @impl Backend
  def steer(%{port: nil}, _text) do
    # Nothing is running, so there is nothing to join. The session falls back to
    # starting a turn.
    {:error, "no live claude process to steer"}
  end

  def steer(handle, text) when is_binary(text) do
    # Same pipe as run_turn/2: Claude Code decides where it lands, and mid-turn
    # it lands at the next tool-result boundary.
    write(handle, message_line(text))
    {:ok, handle}
  end

  defp ensure_process(%{port: port} = handle) when is_port(port) do
    if Port.info(port) == nil do
      # The process died without us noticing. Start a new one rather than
      # writing into a closed pipe.
      spawn_process(%{handle | port: nil, os_pid: nil, buffer: ""})
    else
      {:ok, handle}
    end
  end

  defp ensure_process(handle), do: spawn_process(handle)

  defp spawn_process(handle) do
    with {:ok, exe} <- executable() do
      port =
        Port.open({:spawn_executable, exe}, [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          args: @base_args ++ session_args(handle),
          cd: handle.cwd
        ])

      {:ok,
       %{
         handle
         | port: port,
           os_pid: os_pid(port),
           buffer: "",
           tools: %{},
           first_turn?: false
       }}
    end
  end

  defp write(handle, line), do: Port.command(handle.port, line)

  # The very first turn names the conversation; every later one reattaches to
  # it. Passing both is rejected by the CLI.
  defp session_args(%{first_turn?: true, session_id: id}), do: ["--session-id", id]
  defp session_args(%{session_id: id}), do: ["--resume", id]

  defp message_line(text) do
    Jsonl.line(%{"type" => "user", "message" => %{"role" => "user", "content" => text}})
  end

  @impl Backend
  def interrupt(%{port: nil} = handle), do: {:ok, handle}

  def interrupt(handle) do
    # Asking beats killing: the process survives, so the next turn is still
    # warm. See the moduledoc.
    id = "int_#{handle.next_control_id}"

    write(
      handle,
      Jsonl.line(%{
        "type" => "control_request",
        "request_id" => id,
        "request" => %{"subtype" => "interrupt"}
      })
    )

    {:ok, %{handle | interrupted?: true, next_control_id: handle.next_control_id + 1}}
  end

  @impl Backend
  def release(%{port: nil} = handle), do: {:ok, handle}
  def release(handle), do: {:ok, teardown(handle)}

  @impl Backend
  def persist(handle) do
    %{cc_session_id: handle.session_id, cc_cwd: handle.cwd}
  end

  @impl Backend
  def stop(handle) do
    teardown(handle)
    :ok
  end

  defp teardown(%{port: nil} = handle), do: handle

  defp teardown(handle) do
    kill_tree(handle.os_pid)

    # Close after killing: closing first can make the child exit on a broken
    # pipe before we have snapshotted its children.
    if is_port(handle.port) and Port.info(handle.port) != nil do
      Port.close(handle.port)
    end

    %{handle | port: nil, os_pid: nil, buffer: ""}
  end

  # ── Decoding ──────────────────────────────────────────────────────────────

  @impl Backend
  def decode(%{port: port} = handle, {port, {:data, chunk}}) do
    {lines, buffer} = Jsonl.split(handle.buffer <> chunk)
    {handle, out} = Enum.reduce(lines, {%{handle | buffer: buffer}, []}, &reduce_line/2)
    {:ok, handle, Enum.reverse(out)}
  end

  # Only reachable when the process died on its own: a `result` and an
  # `interrupt` both tear the port down, and a closed port delivers no exit
  # status. So this always means the turn ended with nothing to explain it —
  # and a session left sitting in `:running` with no reason is the failure mode
  # that makes a background agent look hung.
  def decode(%{port: port} = handle, {port, {:exit_status, status}}) do
    {:ok, %{handle | port: nil, os_pid: nil},
     [
       {:event, :turn_failed,
        %{reason: "claude exited with status #{status} before finishing the turn"}}
     ]}
  end

  # The process we killed, confirming it died. Erlang delivers this even after
  # `Port.close/1`, so it has to be swallowed here — falling through to
  # `:ignore` makes the session log a line about it on every single turn.
  def decode(handle, {port, {:exit_status, _status}}) when is_port(port) do
    {:ok, handle, []}
  end

  def decode(_handle, _message), do: :ignore

  defp reduce_line(line, {handle, out}) do
    case Jason.decode(line) do
      {:ok, message} ->
        {handle, produced} = translate(handle, message)
        {handle, Enum.reverse(produced) ++ out}

      {:error, _} ->
        # stderr is not redirected into this stream, so a non-JSON line is a
        # protocol surprise worth seeing — but never worth crashing the session.
        Logger.warning("ClaudeCode: unparseable output line: #{String.slice(line, 0, 200)}")
        {handle, out}
    end
  end

  # ── Translation ───────────────────────────────────────────────────────────

  defp translate(handle, %{"type" => "system", "subtype" => "init"} = message) do
    # Authoritative session id. We minted it, but taking it from here means a
    # future CLI that reassigns ids cannot silently orphan the conversation.
    handle = %{handle | session_id: message["session_id"] || handle.session_id}
    {handle, [{:event, :status, %{status: :running, backend_ref: handle.session_id}}]}
  end

  defp translate(handle, %{"type" => "system", "subtype" => "permission_denied"} = message) do
    # Should be unreachable under bypassPermissions. If it ever fires the model
    # is being silently crippled, so it has to be loud.
    Logger.error("ClaudeCode: permission denied despite automode: #{inspect(message)}")

    {handle,
     [
       {:event, :tool_result,
        %{
          id: message["tool_use_id"],
          name: message["tool_name"],
          status: :error,
          output: message["message"] || "permission denied"
        }}
     ]}
  end

  defp translate(handle, %{"type" => "system"}), do: {handle, []}

  # The ack for our own interrupt. `still_queued` would list messages that
  # survived it, which cannot happen here — the session never writes a second
  # message while it is stopping one.
  defp translate(handle, %{"type" => "control_response"}), do: {handle, []}

  # Each API call announces its own prompt size here. An agentic turn makes
  # several, so this is overwritten each time and the last one wins — that is
  # the number that matters, and `result` cannot give it (see `context/2`).
  defp translate(handle, %{
         "type" => "stream_event",
         "event" => %{"type" => "message_start", "message" => message}
       }) do
    {%{handle | context_tokens: context_of(message["usage"] || %{})}, []}
  end

  defp translate(handle, %{"type" => "stream_event", "event" => event}) do
    {handle, stream_event(handle, event)}
  end

  defp translate(handle, %{"type" => "assistant", "message" => %{"content" => content}})
       when is_list(content) do
    content
    |> Enum.with_index()
    |> Enum.reduce({handle, []}, fn {block, index}, {acc, out} ->
      {acc, produced} = assistant_block(acc, block, index)
      {acc, out ++ produced}
    end)
  end

  defp translate(handle, %{"type" => "user", "message" => %{"content" => content}})
       when is_list(content) do
    produced =
      for %{"type" => "tool_result", "tool_use_id" => id} = block <- content do
        {:event, :tool_result,
         %{
           id: id,
           name: Map.get(handle.tools, id, "tool"),
           status: if(block["is_error"], do: :error, else: :ok),
           output: describe(block["content"])
         }}
      end

    {handle, produced}
  end

  defp translate(handle, %{"type" => "result"} = message) do
    # The process deliberately survives: the next turn starts in 0.02 s instead
    # of 6 s. It is released on the session's idle timer, not here.
    usage = message["usage"] || %{}

    cond do
      handle.interrupted? ->
        # The turn we asked to stop. Claude Code reports it as
        # `error_during_execution`, which is not an error — and the session
        # emits its own abort event, so saying anything here double-reports it.
        {%{handle | interrupted?: false}, []}

      result_ok?(message) ->
        handle = %{handle | context_window: context_window(message)}

        {handle,
         [
           {:event, :turn_done,
            %{
              stop_reason: message["stop_reason"],
              usage: usage,
              context_tokens: handle.context_tokens,
              context_window: handle.context_window
            }}
         ]}

      true ->
        {handle,
         [
           {:event, :turn_failed,
            %{
              reason: message["subtype"] || "unknown",
              terminal_reason: message["terminal_reason"],
              usage: usage
            }}
         ]}
    end
  end

  defp translate(handle, _message), do: {handle, []}

  defp result_ok?(%{"subtype" => "success"}), do: true
  defp result_ok?(_message), do: false

  @doc """
  How big the prompt of one API call was.

  **Not** computed from `result`, which is the sum over every API call in the
  turn. Measured on a four-step shell task:

      call 1  in=2  cache_read=10112  cache_write=20958  ->  31,072
      call 2  in=2  cache_read=31070  cache_write=  141  ->  31,213
      call 3  in=2  cache_read=31211  cache_write=  359  ->  31,572
      call 4  in=2  cache_read=31570  cache_write=  141  ->  31,713
      call 5  in=2  cache_read=31711  cache_write=  141  ->  31,854
      result  in=10 cache_read=135674 cache_write=21740  -> 157,424

  The conversation was 31,854 tokens the whole time; `result` reports the turn's
  total token traffic, because each tool call re-reads the cached prefix. Showing
  that as "context" told the user they were at 157K when they were at 32K.
  """
  def context_of(usage) do
    Enum.sum(
      for key <- ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"],
          is_integer(usage[key]),
          do: usage[key]
    )
  end

  # `modelUsage` is keyed by model id; there is one entry per model the turn
  # used, and all of them report the same window for a single-model turn.
  defp context_window(message) do
    case message["modelUsage"] do
      usage when is_map(usage) ->
        usage |> Map.values() |> Enum.find_value(fn u -> is_map(u) && u["contextWindow"] end)

      _ ->
        nil
    end
  end

  defp assistant_block(handle, %{"type" => "text", "text" => text}, index) do
    {handle, [{:event, :assistant_text, %{block_id: block_id(handle, index), text: text}}]}
  end

  defp assistant_block(handle, %{"type" => "thinking"} = block, index) do
    {handle,
     [
       {:event, :thinking,
        %{block_id: block_id(handle, index), text: Map.get(block, "thinking", "")}}
     ]}
  end

  defp assistant_block(handle, %{"type" => "tool_use", "id" => id, "name" => name} = block, index) do
    # Remembered so the matching tool_result, which only carries the id, can be
    # labelled with the tool that produced it.
    handle = %{handle | tools: Map.put(handle.tools, id, name)}

    {handle,
     [
       {:event, :tool_use,
        %{
          id: id,
          block_id: block_id(handle, index),
          name: name,
          input: Map.get(block, "input", %{})
        }}
     ]}
  end

  defp assistant_block(handle, _block, _index), do: {handle, []}

  # ── SSE passthrough ───────────────────────────────────────────────────────
  #
  # `--include-partial-messages` wraps the raw Anthropic SSE events, which is
  # the same shape the client delta protocol was built around, so this layer is
  # almost a rename.

  defp stream_event(handle, %{
         "type" => "content_block_start",
         "index" => index,
         "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}
       }) do
    [{:delta, %{block_id: block_id(handle, index), type: :tool_use_start, name: name, id: id}}]
  end

  defp stream_event(handle, %{
         "type" => "content_block_start",
         "index" => index,
         "content_block" => %{"type" => type}
       }) do
    [
      {:delta,
       %{block_id: block_id(handle, index), type: :block_start, block_type: atomize(type)}}
    ]
  end

  defp stream_event(handle, %{
         "type" => "content_block_delta",
         "index" => index,
         "delta" => %{"type" => "text_delta", "text" => text}
       }) do
    [{:delta, %{block_id: block_id(handle, index), type: :text, chunk: text}}]
  end

  defp stream_event(handle, %{
         "type" => "content_block_delta",
         "index" => index,
         "delta" => %{"type" => "thinking_delta", "thinking" => text}
       }) do
    [{:delta, %{block_id: block_id(handle, index), type: :thinking, chunk: text}}]
  end

  defp stream_event(handle, %{"type" => "content_block_stop", "index" => index}) do
    [{:delta, %{block_id: block_id(handle, index), type: :block_end}}]
  end

  # `input_json_delta` and `signature_delta` are dropped on purpose: the
  # authoritative version arrives in the `assistant` message, and a client has
  # nothing useful to do with half a JSON argument list.
  defp stream_event(_handle, _event), do: []

  defp atomize("text"), do: :text
  defp atomize("thinking"), do: :thinking
  defp atomize("tool_use"), do: :tool_use
  defp atomize(other), do: String.to_atom(other)

  defp describe(content) when is_binary(content), do: content

  defp describe(blocks) when is_list(blocks) do
    Enum.map_join(blocks, "\n", fn
      %{"type" => "text", "text" => text} -> text
      %{"type" => "image"} -> "[image]"
      other -> "[#{other["type"] || "block"}]"
    end)
  end

  defp describe(other), do: inspect(other)

  # ── Processes ─────────────────────────────────────────────────────────────

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  @doc false
  # Public only so a test can assert the orphan behaviour this exists to prevent.
  def kill_tree(nil), do: :ok

  def kill_tree(os_pid) do
    # Snapshot first: killing the parent reparents the children and loses the
    # relationship, which is exactly how the 224 MB runtime gets orphaned.
    pids = [os_pid | descendants(os_pid)]
    Enum.each(pids, &kill/1)

    Process.sleep(@reap_grace_ms)

    case Enum.filter(pids, &alive?/1) do
      [] -> :ok
      survivors -> Logger.warning("ClaudeCode: processes survived SIGKILL: #{inspect(survivors)}")
    end

    :ok
  end

  defp descendants(os_pid) do
    case cmd("pgrep", ["-P", to_string(os_pid)]) do
      {:ok, output} ->
        children =
          output
          |> String.split(~r/\s+/, trim: true)
          |> Enum.flat_map(fn raw ->
            case Integer.parse(raw) do
              {pid, ""} -> [pid]
              _ -> []
            end
          end)

        children ++ Enum.flat_map(children, &descendants/1)

      :error ->
        []
    end
  end

  defp kill(os_pid), do: cmd("kill", ["-KILL", to_string(os_pid)])

  defp alive?(os_pid) do
    match?({:ok, _}, cmd("kill", ["-0", to_string(os_pid)]))
  end

  defp cmd(binary, args) do
    case System.cmd(binary, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      _ -> :error
    end
  rescue
    # A missing `pgrep`/`kill` must not take the session down with it; the
    # consequence is a leaked process, which the warning above will surface.
    ErlangError -> :error
  end

  # ── Misc ──────────────────────────────────────────────────────────────────

  defp executable do
    configured = Application.get_env(:loom, Loom.Agent, [])[:claude_cli] || "claude"

    case System.find_executable(configured) do
      nil -> {:error, "could not find the `#{configured}` executable on PATH"}
      path -> {:ok, path}
    end
  end

  defp default_cwd do
    Application.get_env(:loom, Loom.Agent, [])[:workspace] || System.user_home!()
  end

  # Qualifies block_ids so indexes from different turns never collide.
  defp turn_ref, do: Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  defp block_id(%{ref: nil}, index), do: "r?.#{index}"
  defp block_id(%{ref: ref}, index), do: "#{ref}.#{index}"

  # Claude Code requires a syntactically valid v4 UUID for --session-id, and
  # rejects anything else. Not worth a dependency.
  defp uuid4 do
    <<head::48, _::4, mid::12, _::2, tail::62>> = :crypto.strong_rand_bytes(16)

    <<head::48, 4::4, mid::12, 2::2, tail::62>>
    |> Base.encode16(case: :lower)
    |> hyphenate()
  end

  defp hyphenate(<<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>>) do
    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end
end
