# Backends: Claude Code, Codex and Kiro

Loom hands the agent itself to these CLIs; Kiro is in §9. Everything below was measured,
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
| `result` with `is_error: true` | `:turn_failed`, reason from `result` (§6.13) |
| `system/api_retry` | `:api_retry` (§6.13) |
| `assistant` with `model: "<synthetic>"` | nothing (§6.13) |
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
| `error` with `willRetry: true` | `:api_retry` (§6.13) |
| `error`, last, inside a turn | nothing: `turn/completed` reports it (§6.13) |

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

### 6.12 A conversation that never ran cannot be resumed

Both backends only write a conversation to disk on its first turn. A session
created and then restarted (a deploy, `/reload`) before anything was sent has
an id and nothing behind it:

- **CC:** `--resume <uuid>` prints `No conversation found` and exits 1, on every
  turn after. The handle's `started?` is set by `system/init`, not by the
  spawn, and persisted as `cc_started`; `--session-id` is used until it is
  true. A header without `cc_started` is checked against
  `~/.claude/projects/*/<uuid>.jsonl`. If a `--resume` still exits before
  `system/init` and the store has no such file, the adapter respawns with
  `--session-id` and rewrites the turn's messages, once.
- **Codex:** `thread/resume` fails with `no rollout found for thread id`. The
  adapter opens a new thread instead, at restore and when reattaching after
  an app-server restart; there is nothing in the old one to lose.

A write to a CLI that has already exited is ignored rather than raised: the
`exit_status` that follows reports it.

### 6.13 The API refusing (Bedrock 503)

**Claude Code:**

CC retries a refused request by itself, 10 times by default
(`CLAUDE_CODE_MAX_RETRIES`), with backoff. Against Bedrock's 503 each attempt
took about 10 s to fail, so the whole run took 4½ minutes (2026-10-19, measured),
and the only output during it is one `system/api_retry` per attempt:

```json
{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":557,"error_status":503,"error":"server_error"}
```

Dropped, it made the turn look hung until it was interrupted. It is now
`:api_retry`, and the chat shows the latest one as a single line.

When it gives up, CC writes its own reply, `model: "<synthetic>"`, with
`API Error: 503 …` as its text, then a `result` that still says `"subtype":
"success"` but has `is_error: true`, `api_error_status` and the same text in
`result`. So `is_error` decides, the turn fails with that text, and the
synthetic reply is dropped, as it would only repeat it as if the model had
said it. The other synthetic replies seen are a safeguard refusal (also
`API Error: …`, the same shape) and `No response requested.` after an
interrupt.

**Codex** (0.162.1) says it in `error` notifications. One per retry, with
`willRetry: true`, `"message": "Reconnecting... 1/5"` and the status under
`codexErrorInfo` (`{"responseStreamDisconnected": {"httpStatusCode": 503}}`);
then one with `willRetry: false`; then `turn/completed` with `status:
"failed"` and the same error. Every `error` used to fail the turn, so the
first retry ended it while Codex was still trying and each later one failed
it again. Now a retry is `:api_retry`, and only `turn/completed` fails it.

Reproduce: a local server answering every POST with 503, and
`ANTHROPIC_BEDROCK_BASE_URL=http://127.0.0.1:<port> CLAUDE_CODE_MAX_RETRIES=3`
for CC; for Codex a `CODEX_HOME` whose provider has `base_url =
"http://127.0.0.1:<port>/v1"`, `wire_api = "responses"` and
`stream_max_retries = 2`.

There is no automatic fallback to another model. When the usual one is down,
the user switches by hand (the composer's model menu, or a session on Codex or
another profile), so which model answered is never a surprise.

### 6.14 Profiles: another provider per session

A Claude Code session can be bound to a profile, `~/.loom/profiles/<name>.json`
(`Loom.Agent.Profiles`), chosen in New chat and fixed like the backend. The file
is a CC settings file passed as `--settings <file>`; its `env` overrides
`~/.claude/settings.json`'s. Measured (CC 2.1.300) against a local capture
server, with `CLAUDE_CODE_USE_BEDROCK=0`, `ANTHROPIC_BASE_URL` and
`ANTHROPIC_AUTH_TOKEN`: CC sent `POST <base>/v1/messages?beta=true` with
`Authorization: Bearer <token>`, and the `ANTHROPIC_DEFAULT_*_MODEL` names went
out as written, no `[1m]` added.

The session header stores only the name, so the key stays in the file and an
edit takes effect at the next spawn. A profile file that has gone missing fails the turn with its name
rather than falling back to the default.

Bedrock's own Anthropic-compatible endpoint
(`https://bedrock-runtime.<region>.amazonaws.com/anthropic`, a
`bedrock-api-key-…` as the bearer token) needs two more variables: CC sends
`metadata.user_id` as a JSON string, which the endpoint rejects ("Request
metadata contains a value that violates the regular expression"), so
`CLAUDE_CODE_EXTRA_BODY={"metadata":{"user_id":"loom"}}` replaces it; and it
rejects CC's experimental `anthropic-beta` values, so
`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`. With both, a Loom session ran tools
and reported a 1M window. The `profiles` skill has the full file.

### 6.15 Switching the model mid-session

The composer's model menu lists `Backend.models/0`. For CC that is three
aliases, `opus`, `sonnet` and `haiku`. The settings in force map each alias to
an id through `ANTHROPIC_DEFAULT_*_MODEL`, so the same three work on every
profile. For Codex it is the app-server's own `model/list`, without the hidden
entries.

A switch is recorded in the header (`model`) and said in the transcript
(`:model_changed`). It applies from the next turn; a turn already running
finishes on its own model. Neither engine restarts:

- **CC.** A process spawned after the switch gets `--model`. A process that is
  already live is sent `{"type":"control_request","request":{"subtype":
  "set_model","model":…}}` just before the next message. Measured (CC 2.1.300):
  opus answered, `set_model haiku` was acknowledged, and the next answer came
  from haiku in the same process, with the conversation intact.
- **Codex.** `turn/start` carries `model` on every turn. Measured: a session
  switched to `openai.gpt-5.5` ran its turn on it, and the context window it
  reported changed to that model's.

Caches are per model. The first turn after a switch writes the whole
conversation into the new model's cache.

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

## 9. Kiro (ACP)

Measured with kiro-cli 3.2.0 and its default v3 engine, on 2026-11-11, on an
Ubuntu 24.04 EC2 instance. Adapter: `Loom.Agent.Backend.Kiro`.

`kiro-cli acp` speaks the [Agent Client Protocol](https://agentclientprotocol.com):
newline-delimited JSON-RPC 2.0 over stdio, plus Kiro's `_kiro/…` and
`_session/…` extensions.

### 9.1 State model: Claude Code's, on Codex's wire

One process per session, spawned on the first turn and released after the idle
timer like CC. One ACP process could hold several sessions, but each is ~580 MB
(a 108 MB Rust relay and a 475 MB Node engine, plus the MCP servers it starts)
and `session/load` reattaches in about 0.9 s across processes, so sharing buys
little and would put every Kiro session in one failure domain.

```
initialize          0.6–0.9 s
session/new         0.85 s     (or session/load: 0.84 s)
first prompt        ~6 s for a one-line answer
```

The handshake runs inside `decode/2` (phases `:initializing → :opening →
:ready`); the prompt typed meanwhile waits in the handle. The session id
(`sess_…`) comes from `session/new` and is persisted as `kiro_session_id`.

### 9.2 Pitfalls

Everything here was measured unless it says otherwise. Kiro's `_kiro/…`,
`_session/…` and `_meta.kiro` extensions are not part of ACP and not
documented, so they are the part most likely to change between releases.

- **Spawn** with `--agent-engine v3 --auth-method cli`, so a release that
  changes the default engine cannot switch the adapter silently.
- **`session/load` replays history** as ordinary `session/update`
  notifications unless `_meta.kiro.noReplay: true` (none with it). Frames
  before `:ready`, and any marked `_meta.kiro.replay: true`, are dropped
  anyway. A failed load opens a new session: one that never ran a prompt was
  never written. A load reply without `modes` is treated as failed
  (defensive, not seen).
- **No system-prompt slot.** `_meta.kiro.steering: [{name, inclusion:
  "always", content}]` on `session/new` and `session/load` is added to Kiro's
  own prompt: Kiro kept its identity and tools and knew a codeword given only
  there, again after a load. It is not kept with the session, so it is sent
  on every load.
- **Permissions.** v3 has no trust-all flag (`--trust-all-tools` and the other
  v2-only flags silently select the v2 engine). `_meta.kiro.policyPreset:
  ["allow-all"]` on new and load approves every tool call for the session: no
  `session/request_permission` at all, and the user's config untouched, which
  answering `allow_always` would not leave (`_kiro/policy/changed`). A
  request that arrives anyway gets the `allow_once` option.
- **`.kiro/settings` is write-protected.** A file-tool write under it (home
  or workspace) is refused outright, `allow-all` notwithstanding, with no
  prompt; `kiro-cli mcp add/remove` run in the shell worked. Loom's
  instructions for Kiro point it at `kiro-cli mcp …` and `/reload`.
- **Questions for the user.** The client declares
  `clientCapabilities._meta.kiro.userInput: true`, so a question the model
  asks comes as the request `_kiro/userInput {sessionId, question,
  options}` rather than as a permission request that allow-once would answer
  "yes". Loom answers `{action: "answered", answer: <nobody is here, use your
  judgement>}` (not seen yet). Other requests (`fs/*`, `terminal/*`; neither
  capability is declared) get a `-32601` error, never silence.
- **A second `session/prompt` cancels the running one** (the first replied
  `cancelled` the moment the second arrived). So steering uses
  `_session/steer {sessionId, message, messageId}`, which replies
  `{queued: true, messageId: "steer-<ours>"}` and is injected at the next
  boundary (`session_info_update` kind `steering_injected`), even into a pure
  text answer. A steer still pending when the prompt replies is sent as the
  next prompt.
- **Interrupt** is the `session/cancel` notification; the prompt replies
  `stopReason: "cancelled"`, which is swallowed. With no reply within 10 s
  the process is killed (defensive).
- **`/compact`** sent as text is just read by the model. It becomes
  `_kiro/session/compact {sessionId}`, which replies `{success: bool}` after
  ~12 s; kind `summarization_completed` is `:compacted`. An automatic one
  runs at `summarizationThreshold` (80 %). After kind `summarization_failed`,
  60 s with no reply fails the turn with the engine's reason (defensive, not
  seen).
- **Context.** `session/prompt` with `_meta.kiro.contextBreakdown: "summary"`
  makes `turn_completion` carry `contextBreakdown.window {sizeTokens,
  usagePercentage}` (1,000,000 here). Between turns, kind `context_usage`
  gives only `usagePercentage`, and a `breakdown` whose per-item tokens and
  percents disagree; the window is inferred from it until the first turn
  completes. Cost is in credits, not shown.
- **Sub-agents.** Frames marked `_meta.kiro.agentSubtaskId` are dropped, so
  a sub-agent's text does not land in the main reply (not seen yet).
- **Text has no block id.** Chunks carry `_meta.kiro.replayId`; a change of
  kind or replayId, a tool call, or the prompt's reply closes a block. Loom
  mints the block ids.
- **Tool output** arrives only with the final `tool_call_update`
  (`content` text, else `rawOutput`) on v3; v2 streams `content` chunks while
  `in_progress`, which become `:tool_output`.
- **Errors.** An error's `data.errorType`, when there is one, is kept in the
  reason. A `model_fallback` info update is logged.
- **Model.** `kiro-cli acp --model` is v2-only too, and v3 ignores Kiro's own
  `chat.defaultModel`. On v3 the model is the `model` config option:
  `session/set_config_option {sessionId, configId: "model", value}`
  (`session/set_model` fails: `-32603 … has no persistence classification`).
  Loom sends `model` and `effortLevel` after every new/load from
  `~/.loom/backends/kiro.json` (`Loom.Agent.BackendConfig`), falling back to
  `LOOM_KIRO_MODEL` for the model.
- **Teardown** kills the tree (`kiro-cli → node → MCP servers`) as for CC.
  Closing stdin alone makes the relay wait 5 s for the engine
  (`the v3 engine did not exit within 5 seconds after ACP stdin closed`).
- kiro-cli logs to stderr (`[INFO] [KRS] …`), which is not redirected.

| Kiro | Loom |
|---|---|
| `session/new` / `session/load` reply | `:running` (if a prompt waits) |
| first `session/update` of a prompt | `:running` |
| `agent_message_chunk` / `agent_thought_chunk` | `:block_start`, `:text` / `:thinking` deltas; `:assistant_text` / `:thinking` on close |
| `tool_call` | `:tool_use_start` delta + `:tool_use` |
| `tool_call_update` `completed` / `failed` | `:tool_result` |
| `session_info_update` `context_usage` | context size |
| `session_info_update` `summarization_completed` | `:compacted` |
| `session/prompt` reply | `:turn_done`, or nothing if cancelled |
| `session/prompt` error | `:turn_failed` |

### 9.3 Reproduce

```sh
kiro-cli acp --agent-engine v3 --auth-method cli
# {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"loom","version":"0"}}}
# {"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/home/ubuntu","mcpServers":[],"_meta":{"kiro":{"policyPreset":["allow-all"],"steering":[{"name":"loom","inclusion":"always","content":"…"}]}}}}
# {"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"sess_…","prompt":[{"type":"text","text":"hi"}]}}
```
