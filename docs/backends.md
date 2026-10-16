# Backends: Claude Code and Codex

Loom hands the agent itself to these two CLIs. Everything below was measured,
not read from docs. Measured with Claude Code 2.1.296 and Codex 0.162.1, on
2026-10-14, on a macOS arm64 laptop unless noted. Loom's own structure is in [architecture.md](architecture.md).

## 1. Why not our own loop

Until 2026-10-14 Loom ran its own loop: about 2,400 lines of tools,
compaction, memory and prompts. Compaction and memory turned out to be
expensive, and they are the least differentiating part. The backends do them
for free. The lock-in is hedged by supporting both, behind the
`Loom.Agent.Backend` behaviour.

## 2. Two different state models

The adapter abstracts per turn, not per process.

**Claude Code: one long-lived process per session.** The session id is set with
`--session-id` and continued with `--resume`, which works across cwds. The cold
start is paid once per session:

```
turn 1 (cold)  init 4.65s  done 9.74s  rss 275MB
turn 2         init 0.02s  done 1.93s
turn 3         init 0.01s  done 1.76s
```

So the process is kept, and released after 15 idle minutes.

**Codex: one shared `codex app-server` for every session.** It speaks
newline-delimited JSON-RPC over stdio. Threads run concurrently and stay
isolated, at about 24 MB RSS in total. `thread/resume` needs only the
`threadId`. Generate decoders from
`codex app-server generate-json-schema --out <dir>` rather than writing them by
hand.

## 3. Mid-turn injection

- **CC:** write another user message to stdin. It is injected at the next
  tool-result boundary, inside the same turn, with one `result`. With no tool
  boundary, it lands in the next turn. Loom does no boundary logic of its own.
- **Codex:** `turn/steer {expectedTurnId}` injects immediately. It fails rather
  than misdelivering if the turn has already ended, and Loom then queues the
  message.

## 4. Interrupt

- **CC:** send `control_request {subtype: "interrupt"}`. The process survives.
  The turn ends with `result/error_during_execution`, which is not an error;
  the handle's `interrupted?` flag silences it. Killing the process also works,
  but it throws away the warm process.
- **Codex:** `turn/interrupt` ends with `turn/completed {status: "interrupted"}`.
  This needs `codex_turn_id` on disk.

## 5. Event mapping

**Claude Code** (`--output-format stream-json --verbose --include-partial-messages`):

| Output | Loom |
|---|---|
| `system/init` | `:running`, records `session_id` |
| `stream_event` block start / delta | `:block_start` / `:tool_use_start` / `:text` / `:thinking` deltas |
| `stream_event message_start` | context size (§6.1) |
| `assistant` | `:assistant_text` / `:thinking` / `:tool_use` |
| `user` (tool_result) | `:tool_result` |
| `result/success` | `:turn_done` |
| `result/error_during_execution` + `interrupted?` | nothing |
| `system/compact_boundary` | `:compacted`; `post_tokens` becomes the context size |

**Codex:**

| Notification | Loom |
|---|---|
| `turn/started` | `:running`, records `turn.id` |
| `item/started` (message / reasoning) | `:block_start` |
| `item/agentMessage/delta`, `item/reasoning/*Delta` | `:text`, `:thinking` |
| `item/started` (command / fileChange / mcp / webSearch) | `:tool_use` |
| `item/*/outputDelta`, `mcpToolCall/progress` | `:tool_output` |
| `item/completed` | final text / thinking / `:tool_result` |
| `thread/tokenUsage/updated` | context size (§6.1) |
| `item/completed` (contextCompaction) | `:compacted` |
| `turn/completed` | `:turn_done`, or nothing if interrupted |

A non-zero `exitCode` overrides `status: "completed"`, which only means the
call finished, not that the command succeeded.

## 6. Pitfalls

### 6.1 Turn-level usage is cumulative

Every tool call re-reads the cached prefix, so turn usage is several times the
real context: 157K reported for a 32K conversation. Use the last call's
numbers instead:

- **CC:** use the last `message_start` usage. The window comes from
  `result.modelUsage[model].contextWindow`.
- **Codex:** use `tokenUsage.last` and `modelContextWindow`, never `total`.

Cost is not shown at all, because Codex reports none.

### 6.2 Codex writer locks outlive a SIGKILL

`<codexHome>/thread-writer-locks/<threadId>.lock` survives a killed process.
Resuming then fails with `-32600 … already has an active writer`.
`Codex.Server` deletes the lock and retries once. This is safe with a single
user and a single instance.

### 6.3 CC is a three-process tree

shim → launcher → runtime. `kill_tree/1` snapshots the descendants with
`pgrep -P` before killing anything, because orphans get reparented to init.
Swallow the `exit_status 137` that arrives after `Port.close/1`.

### 6.4 Two detours, don't go back

- Tearing the process down at `result` made every turn cold.
- Neither tearing down nor keeping it leaked a live port, and every later turn
  hit the "already running" guard. The session was stuck for good.

### 6.5 Interrupted text isn't in the backend's history

That is why `events.jsonl` is only the display truth.

### 6.6 CC flags

Used: `--setting-sources user`. It keeps the user's settings and MCP servers
and ignores any `.claude/settings.local.json` lying around under `$HOME`. With
`--setting-sources ""` the MCP servers are gone too. The prompt cost depends on
the user's MCP setup: on this server (one MCP server, deferred tools) it is
15.7K vs 15.5K tokens; on a Mac with 67 MCP tools it was 31K vs 15.5K. Either
way it is a cached read after the first turn.

Tried and rejected (the first two are tempting because they shrink the prompt):

- `--strict-mcp-config` would drop every MCP server, and MCP is the only
  extension point.
- `--bare` would drop CC's own system prompt and leave only Bash, Edit and
  Read. That system prompt is the reason Loom uses CC at all.
- `-p "<prompt>"` would wait 3 s on stdin and put user text on the command
  line. The prompt goes over stdin with `--input-format stream-json` instead.

### 6.7 Codex history

Pass `excludeTurns: true` to `thread/resume`; full hydration is deprecated.
Read history with `thread/turns/list` + `thread/items/list`. These need no
resume and take no writer lock.

### 6.8 A shared server fails for everyone

When the app-server exits:

1. Every pending call gets `:server_down`.
2. Every thread owner gets `{:codex_down, thread_id}`.
3. Every lock is cleared.

Sessions reattach before their next turn, so the only visible loss is the turn
that was running.

### 6.9 `/compact`

- **CC** runs `/compact` sent as a normal message. The context size comes from
  `post_tokens`.
- **Codex** doesn't run slash commands. A message that is exactly `/compact`
  becomes `thread/compact/start`. Its `tokenUsage.last` is all zeros, so the
  old value is kept.

### 6.10 Resume does not keep the sandbox

A resumed thread falls back to `~/.codex/config.toml`. For an untrusted cwd like
`$HOME` that means `readOnly` with no network. Every restart resumes every
session, so `sandbox` and `approvalPolicy` must be sent on `thread/resume` too,
not only on `thread/start`.

### 6.11 Reloading Codex config

The app-server reads `config.toml`, skills and MCP servers when it starts and
when a thread is created. An existing thread does not see a change, and
`config/mcpServer/reload` covers MCP servers only. So `Server.reload/0` restarts
the whole process once no turn is in flight. A thread counts as in flight from
the moment `turn/start` or `thread/compact/start` is sent until
`turn/completed`.

Calls that arrive while the old process exits wait for the new one. A turn on a
thread the new server has not seen gets `:not_attached`, and the backend resumes
the thread and retries. Measured: a reload requested mid-turn waited for the
turn (`sleep 6` finished), and the restart took about 10 ms. The same thread
then used an MCP server added meanwhile.

## 7. Not done: permission prompts

Codex has proper approval requests. CC auto-denies under
`--permission-prompts host` and would need its own MCP permission tool. Both
run in auto mode instead:

- CC: `--permission-mode bypassPermissions`
- Codex: `approvalPolicy: "never"` + `sandbox: "danger-full-access"`

Unexpected server→client requests must be declined, never ignored. An
unanswered request hangs the turn forever, with no error.

## 8. Reproduce

```sh
echo '{"type":"user","message":{"role":"user","content":"hi"}}' \
| claude -p --verbose --input-format stream-json --output-format stream-json \
         --include-partial-messages --session-id "$SID" \
         --setting-sources user --permission-mode bypassPermissions

codex app-server
# {"id":1,"method":"initialize","params":{"clientInfo":{"name":"loom","version":"0"}}}
# {"id":2,"method":"thread/start","params":{"cwd":"…","sandbox":"danger-full-access","approvalPolicy":"never"}}
# {"id":3,"method":"turn/start","params":{"threadId":"…","input":[{"type":"text","text":"…"}]}}
```
