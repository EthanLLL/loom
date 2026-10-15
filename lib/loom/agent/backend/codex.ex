defmodule Loom.Agent.Backend.Codex do
  @moduledoc """
  Codex as the engine: a thread on the shared `codex app-server`.

  The mirror image of `Loom.Agent.Backend.ClaudeCode`. There, a turn is a process
  we spawn and kill; here it is a pair of JSON-RPC calls into a server that was
  already running and will outlive the turn. `Loom.Agent.Codex.Server` owns that
  process and routes notifications here by `threadId`.

  ## Block identity comes for free

  Codex names every item (`msg_…`, `rs_…`) and repeats that id on each delta, so
  the id *is* the block id — no per-turn qualifier, unlike the SSE `index` Claude
  Code reports, which is only unique within one response.

  ## Tool calls are items, not a separate concept

  A shell command, a patch, an MCP call and a web search all arrive as
  `item/started` then `item/completed` with a different `type`. They map onto the
  existing `:tool_use` / `:tool_result` event pair, so the UI needs no new cards.

  ## Streaming tool output

  `outputDelta` notifications become `:tool_output` deltas carrying the raw
  chunk, keyed by the same `block_id` as the tool card. A long build therefore
  shows progress instead of looking hung, and `item/completed` replaces the
  accumulated text with the authoritative `:tool_result` — the same
  placeholder-then-replace shape text blocks already use.

  Progress notifications that are structured rather than textual
  (`item/mcpToolCall/progress`) are serialised generically. Showing the raw JSON
  beats dropping it: the point of streaming is to prove something is happening,
  and a shape we have not special-cased is still evidence of that.

  ## Compaction and usage are reported, not implemented

  Compaction is the backend's: a `contextCompaction` item is forwarded as an
  event, and `/compact` typed by the user becomes `thread/compact/start` — the
  app-server does not run slash commands itself. `thread/tokenUsage/updated`
  gives the numbers outright — including the model's context window, which Codex
  reports and Claude Code only hints at. This is the part of the old design that
  the backend does for us.

  The notification carries both `last` and `total`, and only `last` is the
  context. Measured on a four-step shell task:

      after echo a   last.input=15154   total.total=15216
      after echo b   last.input=15264   total.total=30519
      after echo c   last.input=15351   total.total=45909
      after echo d   last.input=15436   total.total=61384
      final          last.input=15522   total.total=76954

  The conversation was ~15.5K the whole time; `total` accumulates every API call
  in the turn, because each tool call re-reads the cached prefix.
  """

  @behaviour Loom.Agent.Backend

  require Logger

  alias Loom.Agent.Backend
  alias Loom.Agent.Codex.Server

  @impl Backend
  def start(_session_id, meta) do
    opts = [
      cwd: Backend.meta_get(meta, :codex_cwd) || default_cwd(),
      developer_instructions: Backend.meta_get(meta, :instructions)
    ]

    case Server.start_thread(opts) do
      {:ok, thread_id} -> {:ok, new(thread_id, opts[:developer_instructions])}
      {:error, reason} -> {:error, describe_error(reason)}
    end
  end

  @impl Backend
  def resume(_session_id, meta) do
    case Backend.meta_get(meta, :codex_thread_id) do
      id when is_binary(id) -> resume_thread(id, meta)
      _ -> {:error, "no codex_thread_id recorded for this session"}
    end
  end

  defp resume_thread(id, meta) do
    instructions = Backend.meta_get(meta, :instructions)

    case Server.resume_thread(id, resume_opts(instructions)) do
      {:ok, ^id} ->
        # A turn id recorded before a restart refers to a turn that is no longer
        # running — the server would reject an interrupt for it anyway.
        {:ok, %{new(id, instructions) | turn_id: Backend.meta_get(meta, :codex_turn_id)}}

      {:error, reason} ->
        {:error, describe_error(reason)}
    end
  end

  # Given again on every resume, including the silent one after an app-server
  # respawn, so the thread is never running without them.
  defp resume_opts(instructions), do: [developer_instructions: instructions]

  defp new(thread_id, instructions) do
    %{
      thread_id: thread_id,
      instructions: instructions,
      turn_id: nil,
      aborted?: false,
      stale?: false,
      tools: %{},
      usage: nil,
      context_tokens: 0,
      context_window: nil
    }
  end

  @impl Backend
  def run_turn(%{thread_id: nil}, _text), do: {:error, "no codex thread"}

  # The app-server was respawned under us, so it has never heard of this thread.
  # Reattaching before starting the turn is what makes a restart invisible to
  # the user beyond the one turn that died.
  def run_turn(%{stale?: true} = handle, text) do
    case Server.resume_thread(handle.thread_id, resume_opts(handle.instructions)) do
      {:ok, _} -> run_turn(%{handle | stale?: false}, text)
      {:error, reason} -> {:error, describe_error(reason)}
    end
  end

  def run_turn(handle, text) when is_binary(text) do
    if compact?(text), do: compact(handle), else: start_turn(handle, text)
  end

  defp start_turn(handle, text) do
    case Server.start_turn(handle.thread_id, text) do
      {:ok, turn_id} ->
        {:ok, %{handle | turn_id: turn_id, aborted?: false, tools: %{}}}

      {:error, reason} ->
        {:error, describe_error(reason)}
    end
  end

  # The response carries no turn id; `turn/started` supplies it, as it does for
  # a normal turn, so `interrupt/1` works on a compaction too.
  defp compact(handle) do
    case Server.compact(handle.thread_id) do
      {:ok, _} -> {:ok, %{handle | turn_id: nil, aborted?: false, tools: %{}}}
      {:error, reason} -> {:error, describe_error(reason)}
    end
  end

  # Unlike Claude Code, the app-server does not run slash commands: `/compact`
  # sent as a turn is read by the model as text (measured: it replied "OK" and
  # nothing was compacted). So the exact command is turned into the RPC.
  # Anything else — `/compact` merged with other queued lines, say — stays text.
  defp compact?(text), do: String.trim(text) == "/compact"

  @impl Backend
  def steer(%{turn_id: nil}, _text) do
    # No turn to join. The session falls back to starting one.
    {:error, "no running codex turn to steer"}
  end

  def steer(handle, text) when is_binary(text) do
    if compact?(text) do
      # A compaction cannot join a turn. Refusing puts it in the session's
      # queue, so it runs when this turn ends instead of being read as text.
      {:error, "compaction waits for the running turn"}
    else
      # `expectedTurnId` makes this safe: if the turn ended between the session
      # deciding to steer and this call landing, the server refuses rather than
      # delivering the message into the next turn.
      case Server.steer(handle.thread_id, handle.turn_id, text) do
        {:ok, _} -> {:ok, handle}
        {:error, reason} -> {:error, describe_error(reason)}
      end
    end
  end

  @impl Backend
  def release(handle) do
    # Nothing to release: the app-server is shared by every session and lives as
    # long as the node, so there is no per-session process to reclaim.
    {:ok, handle}
  end

  @impl Backend
  def interrupt(%{turn_id: nil} = handle), do: {:ok, handle}

  def interrupt(handle) do
    case Server.interrupt(handle.thread_id, handle.turn_id) do
      {:ok, _} -> {:ok, %{handle | aborted?: true}}
      {:error, reason} -> {:error, describe_error(reason)}
    end
  end

  @impl Backend
  def persist(handle) do
    %{codex_thread_id: handle.thread_id, codex_turn_id: handle.turn_id}
  end

  @impl Backend
  def stop(%{thread_id: nil}), do: :ok

  def stop(handle) do
    # Releasing drops the writer lock. Skipping it is what leaves a thread
    # unopenable until the lock file is deleted by hand.
    Server.release(handle.thread_id)
    :ok
  end

  defp default_cwd do
    Application.get_env(:loom, Loom.Agent, [])[:workspace] || System.user_home!()
  end

  defp describe_error(:server_down), do: "the codex app-server stopped"
  defp describe_error(reason) when is_binary(reason), do: reason
  defp describe_error(reason), do: inspect(reason)

  # ── Decoding ──────────────────────────────────────────────────────────────

  @impl Backend
  def decode(%{thread_id: thread_id} = handle, {:codex, thread_id, message}) do
    {handle, out} = translate(handle, message["method"], message["params"] || %{})
    {:ok, handle, out}
  end

  # The app-server died. The turn is gone and so is the server's knowledge of
  # this thread; `stale?` makes the next turn reattach first.
  def decode(%{thread_id: thread_id} = handle, {:codex_down, thread_id}) do
    {:ok, %{handle | turn_id: nil, stale?: true},
     [{:event, :turn_failed, %{reason: "the codex app-server restarted mid-turn"}}]}
  end

  def decode(_handle, _message), do: :ignore

  defp translate(handle, "turn/started", params) do
    turn_id = get_in(params, ["turn", "id"])

    {%{handle | turn_id: turn_id}, [{:event, :status, %{status: :running, backend_ref: turn_id}}]}
  end

  defp translate(handle, "turn/completed", params) do
    status = get_in(params, ["turn", "status"])
    handle = %{handle | turn_id: nil}

    cond do
      status == "interrupted" ->
        # We asked for it; the session emits the abort event.
        {%{handle | aborted?: false}, []}

      status == "failed" ->
        {handle, [{:event, :turn_failed, %{reason: turn_error(params)}}]}

      true ->
        {handle, [{:event, :turn_done, done_payload(handle)}]}
    end
  end

  defp translate(handle, "thread/tokenUsage/updated", params) do
    usage = params["tokenUsage"] || %{}

    {%{
       handle
       | usage: usage,
         # `last`, never `total` — see the moduledoc.
         context_tokens: context_of(usage) || handle.context_tokens,
         context_window: usage["modelContextWindow"] || handle.context_window
     }, []}
  end

  defp translate(handle, "item/started", %{"item" => item}) do
    item_started(handle, item["type"], item)
  end

  defp translate(handle, "item/completed", %{"item" => item}) do
    item_completed(handle, item["type"], item)
  end

  defp translate(handle, method, params)
       when method in [
              "item/commandExecution/outputDelta",
              "item/fileChange/outputDelta",
              "process/outputDelta",
              "command/exec/outputDelta"
            ] do
    {handle, [{:delta, %{block_id: params["itemId"], type: :tool_output, chunk: chunk(params)}}]}
  end

  defp translate(handle, "item/mcpToolCall/progress", params) do
    # No text field to take, so `chunk/1` falls through to serialising what is
    # left after the routing keys — which is the progress itself.
    {handle, [{:delta, %{block_id: params["itemId"], type: :tool_output, chunk: chunk(params)}}]}
  end

  defp translate(handle, "item/agentMessage/delta", params) do
    {handle, [{:delta, %{block_id: params["itemId"], type: :text, chunk: params["delta"]}}]}
  end

  defp translate(handle, method, params)
       when method in ["item/reasoning/textDelta", "item/reasoning/summaryTextDelta"] do
    {handle, [{:delta, %{block_id: params["itemId"], type: :thinking, chunk: params["delta"]}}]}
  end

  defp translate(handle, "error", params) do
    {handle, [{:event, :turn_failed, %{reason: params["message"] || inspect(params)}}]}
  end

  defp translate(handle, method, params) when method in ["warning", "guardianWarning"] do
    Logger.warning("Codex warning: #{params["summary"] || inspect(params)}")
    {handle, []}
  end

  # Everything else — status changes, queue changes, MCP startup, plan updates,
  # realtime audio — is either redundant with the events above or has no place
  # in this UI. Dropped rather than guessed at.
  defp translate(handle, _method, _params), do: {handle, []}

  # A compaction reports `last` with every input field 0 (measured), which is
  # "no API call", not "empty context". Keep the old figure until the next turn
  # measures the compacted one, as Claude Code's side does.
  defp context_of(usage) do
    case get_in(usage, ["last", "inputTokens"]) do
      tokens when is_integer(tokens) and tokens > 0 -> tokens
      _ -> nil
    end
  end

  # `delta` is the usual field; some notifications carry `chunk` or a nested
  # object instead. Anything unrecognised is serialised rather than swallowed.
  defp chunk(%{"delta" => delta}) when is_binary(delta), do: delta
  defp chunk(%{"chunk" => chunk}) when is_binary(chunk), do: chunk
  defp chunk(params), do: describe(Map.drop(params, ["threadId", "turnId", "itemId"]))

  defp done_payload(handle) do
    %{
      stop_reason: "end_turn",
      usage: handle.usage,
      context_tokens: handle.context_tokens,
      context_window: handle.context_window
    }
  end

  defp turn_error(params) do
    case get_in(params, ["turn", "error"]) do
      nil -> "the turn failed with no reason given"
      %{"message" => message} -> message
      other -> inspect(other)
    end
  end

  # ── Items ─────────────────────────────────────────────────────────────────

  defp item_started(handle, "agentMessage", item) do
    {handle, [{:delta, %{block_id: item["id"], type: :block_start, block_type: :text}}]}
  end

  defp item_started(handle, "reasoning", item) do
    {handle, [{:delta, %{block_id: item["id"], type: :block_start, block_type: :thinking}}]}
  end

  defp item_started(handle, type, item) when type in ~w(commandExecution fileChange mcpToolCall
                                                        webSearch dynamicToolCall) do
    name = tool_name(type, item)
    handle = %{handle | tools: Map.put(handle.tools, item["id"], name)}

    {handle,
     [
       {:delta, %{block_id: item["id"], type: :tool_use_start, name: name, id: item["id"]}},
       {:event, :tool_use,
        %{id: item["id"], block_id: item["id"], name: name, input: tool_input(type, item)}}
     ]}
  end

  # `userMessage` is our own text echoed back. It is already in the transcript.
  # `contextCompaction` is reported when it completes; see `item_completed/3`.
  defp item_started(handle, _type, _item), do: {handle, []}

  defp item_completed(handle, "agentMessage", item) do
    {handle,
     [
       {:delta, %{block_id: item["id"], type: :block_end}},
       {:event, :assistant_text, %{block_id: item["id"], text: item["text"] || ""}}
     ]}
  end

  defp item_completed(handle, "reasoning", item) do
    {handle,
     [
       {:delta, %{block_id: item["id"], type: :block_end}},
       {:event, :thinking, %{block_id: item["id"], text: reasoning_text(item)}}
     ]}
  end

  defp item_completed(handle, type, item) when type in ~w(commandExecution fileChange mcpToolCall
                                                          webSearch dynamicToolCall) do
    {handle,
     [
       {:event, :tool_result,
        %{
          id: item["id"],
          name: Map.get(handle.tools, item["id"], tool_name(type, item)),
          status: if(failed?(item), do: :error, else: :ok),
          output: tool_output(type, item)
        }}
     ]}
  end

  # What `thread/compact/start` (or an automatic compaction) produces. This
  # replaced the `thread/compacted` notification, which the schema now marks
  # deprecated and 0.162 no longer sends (measured).
  defp item_completed(handle, "contextCompaction", _item) do
    {handle, [{:event, :compacted, %{}}]}
  end

  defp item_completed(handle, _type, _item), do: {handle, []}

  defp failed?(%{"status" => status}) when status in ["failed", "error"], do: true
  defp failed?(%{"exitCode" => code}) when is_integer(code) and code != 0, do: true
  defp failed?(%{"error" => error}) when not is_nil(error), do: true
  defp failed?(_item), do: false

  defp tool_name("commandExecution", _item), do: "shell"
  defp tool_name("fileChange", _item), do: "apply_patch"
  defp tool_name("webSearch", _item), do: "web_search"
  defp tool_name("mcpToolCall", item), do: item["tool"] || "mcp"
  defp tool_name("dynamicToolCall", item), do: item["tool"] || "tool"
  defp tool_name(type, _item), do: type

  defp tool_input("commandExecution", item) do
    %{"command" => item["command"], "cwd" => item["cwd"]}
  end

  defp tool_input("fileChange", item), do: %{"changes" => item["changes"]}
  defp tool_input("webSearch", item), do: %{"query" => item["query"]}
  defp tool_input("mcpToolCall", item), do: item["arguments"] || %{}
  defp tool_input(_type, item), do: item["arguments"] || %{}

  defp tool_output("commandExecution", item), do: item["aggregatedOutput"] || ""
  defp tool_output("webSearch", item), do: describe(item["results"])
  defp tool_output("mcpToolCall", item), do: describe(item["error"] || item["result"])
  defp tool_output("fileChange", item), do: describe(item["changes"])
  defp tool_output(_type, item), do: describe(item["result"])

  # Reasoning text lives in `summary` or `content`, both arrays of blocks whose
  # shape varies by model. Pull out whatever text is there rather than
  # pattern-matching one variant and silently showing nothing for the rest.
  defp reasoning_text(item) do
    (List.wrap(item["summary"]) ++ List.wrap(item["content"]))
    |> Enum.map(&block_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp block_text(%{"text" => text}) when is_binary(text), do: text
  defp block_text(text) when is_binary(text), do: text
  defp block_text(_other), do: ""

  defp describe(nil), do: ""
  defp describe(text) when is_binary(text), do: text

  defp describe(list) when is_list(list) do
    Enum.map_join(list, "\n", fn
      %{"text" => text} when is_binary(text) -> text
      %{"title" => title, "url" => url} -> "#{title} — #{url}"
      other -> inspect(other)
    end)
  end

  defp describe(map) when is_map(map) do
    case map do
      %{"message" => message} when is_binary(message) -> message
      %{"content" => content} -> describe(content)
      other -> inspect(other)
    end
  end

  defp describe(other), do: inspect(other)
end
