# Backends: Claude Code, Codex and Kiro

Loom runs no agent loop of its own. Each session is bound for life to one
conversation in one of three CLIs (`Loom.Agent.Backend` `kind ::
:claude_code | :codex | :kiro`), and the CLI owns the loop, the tools, the
context window, compaction and memory. This file is how each one is driven.

Adapters: `Loom.Agent.Backend.ClaudeCode`, `Loom.Agent.Backend.Codex` (with
`Loom.Agent.Codex.Server`), `Loom.Agent.Backend.Kiro`. Loom's own structure is
in [architecture.md](architecture.md).

"Measured" means observed against the real CLI, not read from its docs:
Claude Code 2.1.296 (profiles and model switching on 2.1.300), Codex 0.162.1,
kiro-cli 3.2.0 with its v3 engine (items marked 3.3.0 were re-measured on
3.3.0). Kiro's `_kiro/…`, `_session/…` and `_meta.kiro` extensions are not part
of ACP and not documented, so they are the part most likely to change.

## 1. The contract

One behaviour, per turn rather than per process:

| Callback | Meaning |
|---|---|
| `start/2`, `resume/2` | open a new conversation, or reattach to the one named in the header |
| `run_turn/2` | start a turn; only called when none is running |
| `steer/2` | inject into the running turn; an error sends the message to the session's queue |
| `interrupt/1` | stop the running turn; the session emits the abort itself |
| `decode/2` | turn a backend message into `{:event, kind, payload}` / `{:delta, map}`, or `:ignore` |
| `persist/1` | what goes into the session header |
| `models/0`, `set_model/2` | the composer's model menu |
| `release/1` | let go of a warm process (idle timer, `/reload`) |
| `stop/1` | the session is deleted |

`decode/2` returns a new handle because identity is learned from output (CC's
`session_id`, Codex's `turn.id`, Kiro's handshake phase). Events carry no seq;
the session numbers them and is the only writer of `events.jsonl`.

Header fields per backend:

| | Claude Code | Codex | Kiro |
|---|---|---|---|
| conversation id | `cc_session_id` (a v4 UUID Loom mints) | `codex_thread_id` | `kiro_session_id` (`sess_…`, from `session/new`) |
| other | `cc_cwd`, `cc_started`, `cc_profile`, `model` | `codex_turn_id`, `codex_profile`, `model` | `kiro_cwd`, `model` |

## 2. Process model

| | Claude Code | Codex | Kiro |
|---|---|---|---|
| process | one `claude -p` per session | one `codex app-server` for all sessions | one `kiro-cli acp` per session |
| spawned | first turn after start or release | at Loom boot | first turn after start or release |
| idle release | yes | no-op | yes |
| size | ~275 MB, +~2 MB per turn | ~24 MB total | ~580 MB (108 MB Rust relay + 475 MB Node engine) plus MCP servers |
| conversation store | `~/.claude/projects/<cwd-slug>/<uuid>.jsonl` | `<codexHome>` rollouts | `~/.kiro/sessions` |

**Claude Code.** The cold start is paid once per session, so the process is
kept between turns:

```
turn 1 (cold)  init 4.65s  done 9.74s  rss 275MB
turn 2         init 0.02s  done 1.93s
turn 3         init 0.01s  done 1.76s
```

stdin is never closed; the process is reclaimed by killing it. Two detours, not
to be repeated: tearing the process down at `result` made every turn cold; and
a version that neither tore it down nor tracked it leaked a live port, after
which every turn hit the "already running" guard for good.

**Codex.** Threads in one app-server run concurrently and stay isolated, so
there is no reason for a process per session. `Codex.Server` owns the port,
correlates JSON-RPC ids, routes notifications by `params.threadId` to the
session that claimed the thread (others are dropped), and answers
server→client requests (§7).

**Kiro.** One ACP process could hold several sessions, but `session/load`
reattaches in ~0.9 s across processes, so sharing buys little and would put
every Kiro session in one failure domain.

```
initialize          0.6–0.9 s
session/new         0.85 s     (or session/load: 0.84 s)
first prompt        ~6 s for a one-line answer
```

**Idle release.** After `LOOM_IDLE_RELEASE_MINUTES` (default 5, a whole number
above 0) with no turn, the session calls `release/1`. A timer that fires while
a turn has started is ignored and rescheduled at its end. The conversation is
unaffected; the next turn pays the cold start.

**`/reload`** (`Loom.Agent.reload_backends/0`) sends every session
`:reload_backend`: idle sessions release now, a session mid-turn sets
`reload_after_turn` and releases when the turn ends. So the next CC or Kiro
spawn rereads settings, MCP servers, skills and (Kiro) the agent file. Codex:
`Codex.Server.reload/0`, §9.3.

**Teardown** (CC and Kiro) is `ClaudeCode.kill_tree/1`: SIGKILL to the process
and every descendant, snapshotted with `pgrep -P` before anything is killed,
because orphans are reparented to init and the relation is lost. CC is three
deep (shim → launcher → runtime; killing the outermost orphaned a 24 MB
launcher and a 224 MB runtime); Kiro is `kiro-cli → node → MCP servers`.
Closing Kiro's stdin alone makes the relay wait 5 s (`the v3 engine did not
exit within 5 seconds after ACP stdin closed`). The port is closed after the
kill; the `exit_status` that still arrives is swallowed.

## 3. Spawning and the wire

### 3.1 Executables and environment

| Variable | Default | Used for |
|---|---|---|
| `LOOM_CLAUDE_CLI` | `claude` | CC executable, looked up on `PATH` |
| `LOOM_CODEX_CLI` | `codex` | Codex executable |
| `LOOM_KIRO_CLI` | `kiro-cli` | Kiro executable (also `chat --list-models`) |
| `LOOM_WORKSPACE` | `$HOME` | cwd of new sessions (all three) |
| `LOOM_KIRO_MODEL` | unset (`auto`) | model a new Kiro session starts on |
| `LOOM_IDLE_RELEASE_MINUTES` | `5` | idle release, CC and Kiro |
| `LOOM_HOME` | `~/.loom` | where profiles live (§10) |

A missing CC or Kiro executable fails the turn (`could not find the `…`
executable on PATH`). The CLIs must already be logged in; Loom passes no
credentials.

Every child gets `Loom.ChildEnv.port_env/1`: Loom's own variables are unset
(`SECRET_KEY_BASE LOOM_PASSWORD PHX_SERVER PHX_HOST PORT LOOM_BIND LOOM_HOME
LOOM_CLAUDE_CLI LOOM_CODEX_CLI LOOM_KIRO_CLI LOOM_WORKSPACE BINDIR ROOTDIR EMU
PROGNAME` and every `RELEASE_*`), and a release's own directories are removed
from `PATH`. A port only adds to the parent's environment, so dropped
variables are passed as `false`. Everything else passes through. stderr is not
redirected into the protocol stream for any of the three; a non-JSON line on
stdout is logged and skipped.

### 3.2 Claude Code: stream-json over stdin/stdout

```
claude -p --verbose --input-format stream-json --output-format stream-json
       --include-partial-messages --setting-sources user
       --permission-mode bypassPermissions
       [--settings <profile>] [--model <alias>]
       (--session-id <uuid> | --resume <uuid>)
       [--append-system-prompt <instructions>]
```

run in `cc_cwd` (else the workspace). A user message is one line:
`{"type":"user","message":{"role":"user","content":"…"}}`.

- `--setting-sources user` loads the user's settings, hooks and MCP servers and
  ignores `project` and `local`, so a stray `.claude/settings.local.json` under
  the cwd changes nothing. `""` drops the MCP servers too. The prompt cost
  depends on the user's MCP setup (measured: 15.5K tokens with none, 31K with
  67 MCP tools); it is a cached read after the first turn.
- Rejected: `--strict-mcp-config` (drops every MCP server, the only extension
  point); `--bare` (drops CC's own system prompt, leaves Bash, Edit, Read);
  `-p "<prompt>"` (waits 3 s for stdin and puts user text in argv).

### 3.3 Codex: JSON-RPC over stdio

`codex app-server`, newline-delimited JSON-RPC (no `jsonrpc` field). Generate
decoders from `codex app-server generate-json-schema --out <dir>` rather than
writing them by hand.

| Call | Params Loom sends |
|---|---|
| `initialize` | `clientInfo {name: "loom", version}`; the reply's `codexHome` locates the writer locks |
| `thread/start` | `cwd`, `sandbox: "danger-full-access"`, `approvalPolicy: "never"`, `developerInstructions` |
| `thread/resume` | `threadId`, `excludeTurns: true`, the same `sandbox`/`approvalPolicy`/`developerInstructions` |
| `turn/start` | `threadId`, `input: [{type: "text", text}]`, `model` if picked |
| `turn/steer` | `threadId`, `expectedTurnId`, `input` |
| `turn/interrupt` | `threadId`, `turnId` |
| `thread/compact/start` | `threadId` |
| `model/list` | `{}` |

Timeouts: 120 s for `thread/start` and `thread/resume` (they start MCP servers
before replying; ~1.7 s measured), 60 s for the rest. `excludeTurns: true`
because full hydration on resume is deprecated; Loom's transcript is its own.

### 3.4 Kiro: ACP

`kiro-cli acp --agent-engine v3 --auth-method cli`, run in `kiro_cwd`, speaks
the [Agent Client Protocol](https://agentclientprotocol.com): newline-delimited
JSON-RPC 2.0 over stdio. The engine is named so a release that changes the
default cannot switch the adapter silently. The v2-only flags
(`--trust-all-tools`, `--model`, …) silently select v2.

The handshake runs inside `decode/2`, phases `:initializing → :opening →
:ready`; a prompt typed meanwhile waits in the handle (a second one replaces
it, a steer is appended to it, an interrupt drops it).

1. `initialize {protocolVersion: 1, clientCapabilities: {fs: {readTextFile:
   false, writeTextFile: false}, terminal: false, _meta: {kiro: {userInput:
   true}}}, clientInfo: {name: "loom", version}}`
2. `session/new {cwd, mcpServers: []}`, or `session/load {sessionId, cwd,
   mcpServers: [], _meta: {kiro: {noReplay: true}}}`. Both carry
   `_meta.kiro.settings.compaction` when set (§8.3). Kiro's own MCP servers
   come through the agent's `includeMcpJson: true`.
3. `session/set_mode {sessionId, modeId: "loom-<id>"}` (§4), then
   `session/set_config_option {sessionId, configId: "model", value}` if a
   model is picked (§5). Sent without waiting; the engine answers in order.
4. `session/prompt {sessionId, prompt: [{type: "text", text}], _meta: {kiro:
   {contextBreakdown: "summary"}}}`

`session/load` replays history as ordinary `session/update` notifications
unless `noReplay` (none with it). Frames before `:ready`, and any marked
`_meta.kiro.replay: true`, are dropped anyway. Frames marked
`_meta.kiro.agentSubtaskId` (a sub-agent's) are dropped too; its result
reaches the main agent as the sub-agent tool's output.

## 4. Instructions

`Loom.Agent.Instructions.for_session/2` builds one text per backend (where the
agent is running, the session's id and directory, that nothing outlives the
turn, images, where files for the user go). No backend keeps it with the
conversation, so it is rebuilt on every start and restore and given again:

- **CC:** `--append-system-prompt <text>` on every spawn, appended to CC's own
  system prompt.
- **Codex:** `developerInstructions` on `thread/start` and on every
  `thread/resume`: at restore, before the next turn after an app-server
  respawn or reload, and on the retry after a stale writer lock is cleared
  (§9.3), which resends the identical params.
- **Kiro:** ACP has no system-prompt slot. Each session gets a Kiro agent,
  `~/.kiro/agents/loom-<id>.md`, written (via a `.tmp` rename) before every
  spawn and removed by `stop/1`:

  ```
  ---
  name: loom-<id>
  description: Loom session <id>; written by Loom at every spawn
  tools: "*"
  includeMcpJson: true
  permissions:
    rules:
      - capability: all
        effect: allow
  ---
  <instructions>
  ```

  v3 lists agents as ACP modes, so `session/set_mode` selects it after every
  new/load; an unknown name replies `{}` and changes nothing. Measured on
  3.3.0: Kiro kept its identity and all 15 tools, knew a codeword given only in
  the file, and still did after a `session/load` in a new process. Cost: the
  user's own `kiro-cli agent list` and TUI modes show every `loom-*` agent.
  (`_meta.kiro.steering` on new/load did the same before; undocumented.)

  Kiro refuses file-tool writes under `.kiro/settings` (home or workspace),
  `allow` notwithstanding, with no prompt; `kiro-cli mcp add/remove` in the
  shell works. Kiro's instructions say so, and to ask for `/reload` after.

## 5. Models

The composer lists `models/0`; `Session.set_model/2` refuses an id that is not
in that list (so nothing can be picked while Codex is down or Kiro's list
failed). A switch is stored in the header (`model`), emitted as
`:model_changed`, and applies from the next turn; a running turn finishes on
its model. No engine restarts.

| | `models/1` | How it is applied |
|---|---|---|
| CC | `opus` (default), `sonnet`, `haiku` | spawn: `--model`. Live process: `{"type":"control_request","request_id":…,"request":{"subtype":"set_model","model":…}}` just before the next message |
| Codex | `model/list`, minus `hidden`, default from `isDefault`; `[]` when the server is down. On a profile, its `models`, the first the default | `model` on every `turn/start`; on a profile, also on `thread/start` and `thread/resume` |
| Kiro | `kiro-cli chat --list-models --format json` (~2.5 s, 15 s timeout), cached 10 min; `auto` is the default | `session/set_config_option configId "model"` after every new/load and before a turn when it changed |

- **CC.** The settings in force map each alias to an id through
  `ANTHROPIC_DEFAULT_*_MODEL`, so the same three work on every profile.
  Measured: opus answered, `set_model haiku` was acknowledged, the next answer
  came from haiku in the same process with the conversation intact.
- **Codex.** Measured: a switched session ran its turn on the new model and
  reported that model's context window.
- **Kiro.** `session/set_model` fails (`-32603 … has no persistence
  classification`) and v3 ignores `chat.defaultModel`, so the config option is
  the only way. A new session starts on `LOOM_KIRO_MODEL` if set, else `auto`.
  A refused `set_config_option` is logged only.

Caches are per model: the first turn after a switch writes the whole
conversation into the new model's cache. There is no automatic fallback to
another model; Kiro's own `model_fallback` info update is logged.

## 6. Event mapping

### 6.1 Claude Code

| stdout | Loom |
|---|---|
| `system/init` | `:status running`; `session_id` taken as authoritative; `started?` set |
| `stream_event message_start` | records the API call's message id (block ids are `<message id>.<index>`) and its context size (§6.4) |
| `stream_event content_block_start` (tool_use) | `:tool_use_start` delta |
| `stream_event content_block_start` (other) | `:block_start` delta |
| `stream_event content_block_delta` text / thinking | `:text` / `:thinking` delta |
| `stream_event content_block_stop` | `:block_end` delta |
| `input_json_delta`, `signature_delta` | nothing (the `assistant` message is authoritative) |
| `assistant` text / thinking / tool_use blocks | `:assistant_text` / `:thinking` / `:tool_use` |
| `assistant` with `model: "<synthetic>"` | nothing (§11) |
| `user` with `tool_result` blocks | `:tool_result`, `:error` if `is_error` |
| `system/permission_denied` | `:tool_result` with `:error`, logged as an error (should not happen under bypass) |
| `system/compact_boundary` | `:compacted {trigger, pre_tokens, post_tokens}`; `post_tokens` becomes the context size |
| `system/api_retry` | `:api_retry {attempt, max_retries, delay_ms, status, error}` |
| other `system/*`, `control_response` | nothing |
| `result` after our interrupt | nothing |
| `result` `subtype: "success"`, not `is_error` | `:turn_done`, window from `modelUsage` |
| `result` with `is_error: true`, or any other subtype | `:turn_failed`, reason `result` text, else the subtype |
| process exits on its own | `:turn_failed` "claude exited with status N before finishing the turn" (also between turns) |

CC splits one API call's blocks across several `assistant` messages, so an
event's block id is matched to the deltas by order (tool_use by id), not by
position in `content`. The SSE `index` restarts in every API call, which is why
block ids are qualified by the call's message id, not by the turn.

### 6.2 Codex

| Notification | Loom |
|---|---|
| `turn/started` | `:status running`; records `turn.id` |
| `item/started` agentMessage / reasoning | `:block_start` delta (block id = item id) |
| `item/agentMessage/delta` | `:text` delta |
| `item/reasoning/textDelta`, `item/reasoning/summaryTextDelta` | `:thinking` delta |
| `item/started` commandExecution / fileChange / mcpToolCall / webSearch / dynamicToolCall | `:tool_use_start` delta + `:tool_use` |
| `item/commandExecution/outputDelta`, `item/fileChange/outputDelta`, `process/outputDelta`, `command/exec/outputDelta` | `:tool_output` delta |
| `item/mcpToolCall/progress` | `:tool_output` delta, the params serialised |
| `item/completed` agentMessage / reasoning | `:block_end` delta + `:assistant_text` / `:thinking` |
| `item/completed` tool items | `:tool_result` |
| `item/completed` contextCompaction | `:compacted` |
| `item/*` userMessage | nothing (our own text) |
| `thread/tokenUsage/updated` | context size (§6.4) |
| `turn/completed` `interrupted` | nothing |
| `turn/completed` `failed` | `:turn_failed`, reason `turn.error.message` |
| `turn/completed` otherwise | `:turn_done` |
| `error` with `willRetry: true` | `:api_retry` (attempt/max parsed from "Reconnecting... 1/5", status from `codexErrorInfo.*.httpStatusCode`) |
| `error` with a `turnId` | nothing: `turn/completed` reports it |
| `error` without a `turnId` | `:turn_failed` |
| `warning`, `guardianWarning` | logged only |
| everything else | nothing |
| `{:codex_down, id}` (app-server died) | `:turn_failed` "the codex app-server restarted mid-turn"; handle marked stale |
| `{:codex_reloaded, id}` | nothing; handle marked stale |

A tool item fails (`:error`) if `status` is `failed` or `error`, or
`exitCode` is a non-zero integer, or `error` is non-nil. `status:
"completed"` only means the call finished, not that the command succeeded.
Tool names: `shell`, `apply_patch`, `web_search`, else the item's `tool`.

### 6.3 Kiro

| ACP | Loom |
|---|---|
| `session/new` / `session/load` reply | phase `:ready`; if a prompt waits, sends it and `:status running` |
| first live `session/update` of a prompt | `:status running` (a warm process has no handshake to say so) |
| `agent_message_chunk` / `agent_thought_chunk` | `:block_start`, `:text` / `:thinking` deltas; on close `:block_end` + `:assistant_text` / `:thinking` |
| `tool_call` (new id) | closes the open block; `:tool_use_start` delta + `:tool_use` |
| `tool_call` (known id), `tool_call_update` in progress with content | `:tool_output` delta (v2 streams; v3 sends only the final result) |
| `tool_call_update` `completed` / `failed` | `:tool_result` (`content` text, else `rawOutput`) |
| `session_info_update` `context_usage` | context size (§6.4) |
| `session_info_update` `turn_completion` | real window and context size (§6.4) |
| `session_info_update` `steering_injected` | steer marked delivered |
| `session_info_update` `summarization_completed` (status nil / success) | `:compacted` |
| `session_info_update` `summarization_failed` | reason kept; 60 s with no prompt reply fails the turn |
| `session_info_update` `model_fallback` | logged |
| other updates (plans, modes, commands, our echo) | nothing |
| prompt reply, steers still pending | the steers' text becomes the next prompt; the turn goes on |
| prompt reply `stopReason: "cancelled"` | nothing |
| prompt reply `stopReason: "refusal"` | `:turn_failed` "the model refused to continue" |
| prompt reply `{success: false}` (compaction) | `:turn_failed` "kiro could not compact the conversation[: reason]" |
| prompt reply otherwise | `:turn_done`, `stop_reason` = `stopReason` |
| prompt error | `:turn_failed`, message (+ `data.message`, + `data.errorType`) |
| `initialize` or `session/new` error | process killed, `:turn_failed` "kiro <step> failed: …" |
| `session/load` error, or reply without `modes` | `session/new` instead |
| exit during a prompt or handshake | `:turn_failed` "kiro-cli exited with status N before finishing the turn" |
| exit between turns | logged only |

ACP text has no block id. A change of kind or of `_meta.kiro.replayId`, a tool
call, or the prompt's reply closes a block; Loom mints random block ids
(`kiro.<hex>`), since a counter would restart with the process. Tool names:
`_meta.kiro.toolName`, else `kind` (`execute` → `shell`, …), else `title`.

### 6.4 Context size

Turn-level usage is cumulative: every tool call re-reads the cached prefix, so
a 32K conversation reported 157K. Each adapter takes the last call instead:

- **CC:** the last `message_start`'s `input_tokens + cache_read_input_tokens +
  cache_creation_input_tokens`; the window from
  `result.modelUsage[*].contextWindow`. After a compaction, `post_tokens`.
- **Codex:** `tokenUsage.last.inputTokens` (never `total`) and
  `modelContextWindow`. A compaction reports `last` as all zeros, so a zero
  keeps the old figure.
- **Kiro:** only percentages of an unnamed window. `turn_completion`
  (requested by `contextBreakdown: "summary"`) carries
  `contextBreakdown.window {sizeTokens, usagePercentage}`. Between turns,
  `context_usage` gives `usagePercentage` and a `breakdown` whose tokens and
  percents disagree; the window is inferred from the item with the most
  tokens, snapped to 128K / 200K / 256K / 400K / 1M / 2M, else the last known
  window, else 1M. The `session/load` reply's `_meta.contextUsage` seeds it.

Cost is not shown: Codex reports none, Kiro reports credits.

## 7. Permissions and approvals

Nobody is there to approve, so all three run in auto mode, and any request
from a backend is answered: an unanswered JSON-RPC request hangs the turn
forever with no error.

- **CC:** `--permission-mode bypassPermissions`. (`--permission-prompts host`
  auto-denies; approvals would need an MCP permission tool.) A
  `system/permission_denied` is surfaced as a failed tool call and logged as
  an error.
- **Codex:** `approvalPolicy: "never"` and `sandbox: "danger-full-access"` on
  start and every resume. Server requests are still answered:
  `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`,
  `item/permissions/requestApproval` → `{decision: "decline"}`;
  `item/tool/requestUserInput` → `{response: null}`; anything else → `{}`.
  All logged.
- **Kiro:** v3 has no trust-all flag. The session agent's `permissions: {rules:
  [{capability: all, effect: allow}]}` approves every tool call without
  touching the user's config (measured: no `session/request_permission` while
  running shell commands; answering `allow_always` would write the user's
  policy, `_kiro/policy/changed`). One that arrives anyway gets the
  `allow_once` option, else `allow_always`, else `{outcome: "cancelled"}`
  (logged). Because `_meta.kiro.userInput: true` is declared, a question for
  the user comes as `_kiro/userInput {sessionId, question, options}` instead of
  a permission request that allow-once would answer "yes"; Loom answers
  `{action: "answered", answer: "The user is not available to answer
  questions mid-turn. Use your best judgement, say what you assumed, and
  continue."}`. `fs` and `terminal` are declared false, and any other request
  (`fs/*`, `terminal/*`, …) gets error `-32601`.

## 8. Turn control

### 8.1 Steering

A message typed mid-turn is handed to `steer/2`, not queued. If steering
fails, it joins the session's queue and goes out with the next turn.

- **CC:** the same stdin line as a new message. Injected at the next
  tool-result boundary inside the same turn, one `result` (measured: sent 16 s
  into a five-step shell task, it arrived with step two's output and steps
  three to five were dropped). With no boundary left it lands in the next
  turn. Refused only when there is no process.
- **Codex:** `turn/steer {expectedTurnId}` injects immediately (measured
  0.0 s), and fails rather than misdelivering if the turn has ended. A
  message that is exactly `/compact` is refused, so it waits in the queue.
- **Kiro:** a second `session/prompt` cancels the running one, so steering is
  `_session/steer {sessionId, message, messageId}`. It replies `{queued: true,
  messageId: "steer-<ours>"}` and is injected at the next boundary
  (`steering_injected`), even into a pure text answer; Kiro's reply then
  carries a `[STEERING steer-…: …]` line of its own. Not in the 44
  advertised `extensionMethods`, but works (measured on 3.3.0). A steer still
  pending when the prompt replies is sent as the next prompt; a refused steer
  is logged and lost.

### 8.2 Interrupt

- **CC:** `control_request {subtype: "interrupt"}`. The process survives (the
  ack is `{"still_queued": []}`). The turn ends with
  `result/error_during_execution`, `terminal_reason: "aborted_streaming"`,
  which `interrupted?` swallows. Killing works too but loses the warm process.
- **Codex:** `turn/interrupt`, ending in `turn/completed {status:
  "interrupted"}`.
- **Kiro:** the `session/cancel` notification; the prompt replies
  `stopReason: "cancelled"`. No reply within 10 s kills the process.

Interrupted text is not in the backend's history, which is why
`events.jsonl` is only the display truth.

### 8.3 Compaction

- **CC:** `/compact` sent as an ordinary message; CC runs it (measured 15.7K →
  1.3K) and reports only `compact_boundary`, then an empty `result/success`.
- **Codex:** the app-server does not run slash commands (sent as text, the
  model replied "OK"). A message that is exactly `/compact` becomes
  `thread/compact/start`, which replies `{}` and runs as an ordinary turn.
  `thread/compacted` is deprecated and no longer sent on 0.162.
- **Kiro:** sent as text it is just read. Exactly `/compact` becomes
  `_kiro/session/compact {sessionId}` (advertised), which replies `{success:
  bool}` after ~12 s. Automatic compaction runs at
  `summarizationThreshold` (80 %). Over ACP the engine ignores
  `~/.kiro/settings/cli.json` and takes the threshold only from
  `_meta.kiro.settings.compaction {enabled: true, autoCompactionThreshold}` on
  new and load (a load without it is back at 80; measured on 3.3.0). So Loom
  reads `compaction.autoCompactionThreshold` from that file at every spawn and
  passes it on both; `kiro-cli settings` stays the one place to set it. An
  out-of-range value (outside 0–80) is the engine's to reject: the session
  fails to open with its message.

## 9. Resume and recovery

### 9.1 Reattaching

- **CC:** `--resume <uuid>`, which finds the conversation in any cwd.
  `--session-id` until `cc_started` is true (set by `system/init`, not by the
  spawn). A header without `cc_started` is checked against
  `$CLAUDE_CONFIG_DIR` (else `~/.claude`)`/projects/*/<uuid>.jsonl`.
- **Codex:** `thread/resume` needs only the `threadId`. `sandbox` and
  `approvalPolicy` must be resent: a resumed thread otherwise falls back to
  `config.toml`, which for an untrusted cwd like `$HOME` is read-only with no
  network.
- **Kiro:** `session/load` on the first turn after spawn. A session restored
  before its first turn has no `kiro_session_id` and just opens one.

A session found mid-turn on disk after a restart comes back `:interrupted`, not
resumed: the turn died with the node, and resending would put the user's
message into the backend's history twice.

### 9.2 A conversation that never ran

All three write a conversation only on its first turn. A session created and
restarted before anything was sent has an id and nothing behind it:

- **CC:** `--resume` prints `No conversation found` and exits 1. If a
  `--resume` spawn exits before `system/init` and the store has no such file,
  the adapter respawns with `--session-id` and rewrites the lines already sent
  to it, once.
- **Codex:** `thread/resume` fails `no rollout found for thread id`; the
  adapter opens a new thread, at restore and when reattaching after a respawn.
- **Kiro:** a failed `session/load` opens a new session.

A write to a CLI that has already exited is ignored; the `exit_status` that
follows reports it.

### 9.3 Codex: one server, shared failure

**Writer locks.** `<codexHome>/thread-writer-locks/<threadId>.lock` survives a
SIGKILL, and resume then fails `-32600 … already has an active writer`. On that
error `Codex.Server` deletes the lock and sends the same `thread/resume` again
(instructions included), once; a second refusal is returned. Locks are also
deleted when a thread is released, when its session process dies, and for
every thread when the app-server exits. Safe only with one Loom per
`codexHome`.

**The app-server exits.** Every pending call gets `:server_down` ("the codex
app-server stopped"), every owner `{:codex_down, thread_id}`, every lock is
deleted, and the server is respawned after a delay that starts at 1 s and
doubles to 60 s while the executable cannot be spawned (a successful spawn
resets it, so a codex that starts and exits is retried every second). While it
is down, every call returns `:server_down` at once and `models/0` is empty;
the rest of Loom runs. A session reattaches (`thread/resume`) before its next
turn, so the only loss is the turn that was running.

**Reload.** The app-server reads `config.toml`, skills and MCP servers at start
and at thread creation; `config/mcpServer/reload` covers MCP only. So
`reload/0` SIGTERMs the process once no thread has a turn in flight (from
`turn/start` or `thread/compact/start` until `turn/completed`) and no call is
pending. Calls arriving meanwhile wait and run on the new process; owners get
`{:codex_reloaded, _}` and reattach before their next turn. A turn on a thread
the new server has not seen gets `:not_attached`, and the adapter resumes and
retries. Measured: a reload requested mid-turn waited for the turn, the
restart took ~10 ms, and the thread then used an MCP server added meanwhile.

## 10. Profiles (Claude Code and Codex)

A CC or Codex session can be bound at creation to a profile,
`$LOOM_HOME/profiles/<backend>/<name>.json` (`Loom.Agent.Profiles`). Names
match `^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$`. Creating a Kiro session with a
profile, or naming one of another backend's, is refused.

The header stores only the name, so the key stays in the file and an edit takes
effect at the next spawn (CC) or resume (Codex). A profile that has gone
missing fails the turn with its name rather than falling back to the default.

### Claude Code

`profiles/claude_code/<name>.json` is a CC settings file passed as
`--settings <file>`; its `env` overrides `~/.claude/settings.json`'s.

Measured against a local capture server with `CLAUDE_CODE_USE_BEDROCK=0`,
`ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN`: CC sent `POST
<base>/v1/messages?beta=true` with `Authorization: Bearer <token>`, and the
`ANTHROPIC_DEFAULT_*_MODEL` names went out as written, no `[1m]` added.

Bedrock's Anthropic-compatible endpoint
(`https://bedrock-runtime.<region>.amazonaws.com/anthropic`, a Bedrock API key
as the bearer token) needs two more variables: it rejects CC's
`metadata.user_id` (a JSON string; "Request metadata contains a value that
violates the regular expression"), so
`CLAUDE_CODE_EXTRA_BODY={"metadata":{"user_id":"loom"}}`; and it rejects CC's
experimental `anthropic-beta` values, so
`CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`. With both, a session ran tools and
reported a 1M window. The `profiles` skill has the full file.

### Codex

`profiles/codex/<name>.json` is `{"base_url", "api_key", "models"}`, with
optional `http_headers`. On `thread/start` and every `thread/resume` the
adapter sends

```json
{"modelProvider": "<name>",
 "config": {"model_providers": {"<name>": {"name": "<name>", "base_url": "…",
   "experimental_bearer_token": "…", "wire_api": "responses", "http_headers": {}}}},
 "model": "<the session's model, else the profile's first>"}
```

Measured on 0.162.1, against a capture server and a real relay:

- Requests go to `<base_url>/responses` with `Authorization: Bearer <key>`.
  Threads on one app-server, each on its own provider, stay apart, interleaved
  turns included; a `model` on `turn/start` keeps the thread's provider.
- A resume without the provider fails, "Model provider '<name>' not found",
  rather than falling back. Loom resumes every session at boot, hence on
  every resume.
- The key is written nowhere under `CODEX_HOME`; rollouts record the
  provider's name alone. Not `env_key`: Codex's shell snapshots export the
  app-server's environment, so the agent could read every provider's key.
- Only the Responses API: `wire_api = "chat"` is refused as no longer
  supported.
- `model/list` knows only the default provider, hence the profile's own list.
  A model missing from `model_catalog_json` logs "Model metadata for … not
  found" each turn and runs on fallback metadata (a 258k window); turns,
  tools and resume were unaffected.

## 11. The API refusing

**CC** retries a refused request itself (`CLAUDE_CODE_MAX_RETRIES`, default
10, with backoff). Against a 503 each attempt took ~10 s, so the run took 4½
minutes, and the only output is one `system/api_retry` per attempt:

```json
{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":557,"error_status":503,"error":"server_error"}
```

When it gives up, CC writes a reply of its own (`model: "<synthetic>"`, text
`API Error: 503 …`), then a `result` that says `"subtype": "success"` with
`is_error: true`, `api_error_status` and the same text. So `is_error` decides,
and the synthetic reply is dropped. Other synthetic replies seen: a safeguard
refusal (same shape) and `No response requested.` after an interrupt.

**Codex** sends one `error` per retry (`willRetry: true`, `"Reconnecting...
1/5"`, `codexErrorInfo: {"responseStreamDisconnected": {"httpStatusCode":
503}}`), one with `willRetry: false`, then `turn/completed {status:
"failed"}`. Only the last fails the turn; failing on every `error` ended the
turn at the first retry and failed it again at each later one.

**Kiro:** Loom maps no retry notification. A `session/prompt` error fails the
turn with its message and `data.errorType`; a `model_fallback` is logged.

Reproduce with a local server answering every POST with 503:
`ANTHROPIC_BEDROCK_BASE_URL=http://127.0.0.1:<port> CLAUDE_CODE_MAX_RETRIES=3`
for CC; for Codex a `CODEX_HOME` whose provider has `base_url =
"http://127.0.0.1:<port>/v1"`, `wire_api = "responses"`, `stream_max_retries =
2`.

## 12. Reproduce by hand

```sh
echo '{"type":"user","message":{"role":"user","content":"hi"}}' \
| claude -p --verbose --input-format stream-json --output-format stream-json \
         --include-partial-messages --setting-sources user \
         --permission-mode bypassPermissions --session-id "$(uuidgen)"
```

```sh
codex app-server
# {"id":1,"method":"initialize","params":{"clientInfo":{"name":"loom","version":"0"}}}
# {"id":2,"method":"thread/start","params":{"cwd":"/path/to/workspace","sandbox":"danger-full-access","approvalPolicy":"never","developerInstructions":"…"}}
# {"id":3,"method":"turn/start","params":{"threadId":"…","input":[{"type":"text","text":"hi"}]}}
```

```sh
# with ~/.kiro/agents/loom-x.md as Loom.Agent.Backend.Kiro.agent_file/1 writes it (§4)
kiro-cli acp --agent-engine v3 --auth-method cli
# {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false,"_meta":{"kiro":{"userInput":true}}},"clientInfo":{"name":"loom","version":"0"}}}
# {"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/path/to/workspace","mcpServers":[]}}
# {"jsonrpc":"2.0","id":3,"method":"session/set_mode","params":{"sessionId":"sess_…","modeId":"loom-x"}}
# {"jsonrpc":"2.0","id":4,"method":"session/set_config_option","params":{"sessionId":"sess_…","configId":"model","value":"auto"}}
# {"jsonrpc":"2.0","id":5,"method":"session/prompt","params":{"sessionId":"sess_…","prompt":[{"type":"text","text":"hi"}],"_meta":{"kiro":{"contextBreakdown":"summary"}}}}
```
