# Architecture

Loom is a single-user lobby for cloud agents. Every device connects to the same
session; state lives on the server and on disk; the agent itself is Claude Code
or Codex. Protocol details are in [backends.md](backends.md), and deployment is
in [deploy.md](deploy.md).

## 1. Non-goals

- **Multi-tenancy.** One password, one token for every device. Agents run as
  the BEAM's uid, with no sandbox.
- **Permission prompts.** Everything runs in auto mode. Nobody is around to
  press `y`, so a prompt would only stall the agent.
- **Our own agent loop.** Tools, context, compaction and memory belong to the
  backend. Why the old in-house loop went: [backends.md §1](backends.md).
- **A per-session working directory.** Every session starts in `$HOME`, or
  `LOOM_WORKSPACE` if set. The project you are working on is a fact in the
  conversation, not configuration.

## 2. One session, one GenServer

```
Loom.Agent.Session        one process per session, restart: :transient
  ├─ Loom.Agent.Backend   adapter behaviour (ClaudeCode, Codex)
  ├─ Loom.Agent.Store     meta.json + events.jsonl
  └─ PubSub "agent:<id>"  events and deltas
```

There is one process per session because failures and turn state are
per-session: one bad response must not take nine other transcripts down with
it. The process holds no sockets, so a turn finishes even with every browser
closed.

### 2.1 States

```
:idle ─submit→ :starting ─backend up→ :running ─turn ends→ :idle
                                         │ interrupt
                                         ↓
                                   :interrupted ─submit→ :starting
```

- **`:starting`** covers the backend's cold start, which takes seconds.
- **`:interrupted`** exists only to suppress "idle with a queue → dequeue".
  After a stop, nothing moves on its own. Typing resumes the session, and the
  parked messages go out with the new one.

### 2.2 Submit

| State | Action | Returns |
|---|---|---|
| `:idle` | start a turn | `:started` |
| `:starting` / `:running` | steer into the current turn | `:steered` |
| steer rejected | queue | `:queued` |
| `:interrupted` | queue + new message, start a turn | `:started` |

Both backends support mid-turn injection natively, so nothing waits for a turn
to end. The queue only holds two things: messages typed while interrupted, and
steers that were rejected (Codex's `expectedTurnId` mismatch). It is persisted
to disk.

### 2.3 Crash recovery

When the supervisor restarts a session with its original spec, `init/1` finds
`meta.json` on disk and reattaches; the disk always wins over the spec. A
crash mid-turn is treated as an involuntary interrupt. The turn died with the
node, and resending it would show the model the message twice. So the session
comes back `:interrupted`, with its queue kept and a status event explaining
why.

### 2.4 `/reload`

Loom's own command; it never reaches a backend. Typed in any session, it tells
every session to let its backend process go: right away if idle, at the end of
the turn if not. The next Claude Code turn is then a fresh `claude --resume`
that reads the new settings, MCP servers and skills. Codex has one shared
app-server, which restarts itself as soon as no Codex turn is running. Its
threads are reattached silently on their next turn
([backends.md §6.11](backends.md)). Only a message that is exactly `/reload`
counts. The composer suggests `/compact`, `/reload` and `/cron` when the first
character is `/`.

### 2.5 Scheduled prompts

`Loom.Cron` submits a fixed prompt to an existing session at every match of a
five-field cron expression, always in UTC. The turn is an ordinary one, so its
reply, outputs and canvas land in that session like any other; a backend's own
scheduler would run outside Loom and update nothing. The message is marked
`origin: "cron"` and a busy session steers or queues it as usual.

- **Truth is `~/.loom/cron.json`.** One process under the supervisor reads it
  at boot and rewrites it on every change; `next_at` is never stored. Minutes
  missed while Loom was down are skipped, not caught up.
- **No HTTP API.** Jobs are made on the node itself, by an agent or by hand,
  with `bin/loom rpc`. The prompt goes in a `~S"""` heredoc, so quotes,
  newlines and `#{}` arrive verbatim:

  ```sh
  bin/loom rpc 'IO.inspect(Loom.Cron.add(%{name: "CI", cron: "30 0 * * 1-5",
    target: "a_…", prompt: ~S"""
  …
  """}))'
  bin/loom rpc 'IO.inspect(Loom.Cron.list())'
  bin/loom rpc 'IO.inspect(Loom.Cron.delete("c_…"))'
  ```

- **`/cron`**, typed in any session, lists every job. Like `/reload`, it never
  reaches a backend.

## 3. Client protocol

```
event  has a seq, persisted to events.jsonl, replayed on reconnect. The truth.
delta  no seq, transient, never replayed. The typewriter.
```

Deltas append to a placeholder keyed by `block_id`. The event carrying the same
`block_id` then replaces the placeholder whole. A stream cut mid-sentence
therefore costs nothing.

Delta types: `:block_start`, `:block_end`, `:text`, `:thinking`,
`:tool_use_start`, and `:tool_output` (Codex only). `:tool_output` reuses the
tool card's `block_id`, the same pattern as text.

- **Loom owns `seq`.** The session is the only writer of `events.jsonl`. Backend
  ids go into `backend_ref` and are used for dedup on reattach.
- **Multiple devices.** A client joins with the last `seq` it saw and receives
  only the gap. PubSub does the fan-out. The channel holds no state.
- **Session list.** It is pushed on the `agents` lobby channel, not polled.

## 4. Storage

```
~/.loom/sessions/<id>/meta.json      header, rewritten atomically (temp + rename)
~/.loom/sessions/<id>/events.jsonl   normalized transcript, append-only, :sync
~/.loom/sessions/<id>/files/…        user attachments
~/.loom/sessions/<id>/output/…       files the agent made for the user
~/.loom/cron.json                    scheduled prompts (§2.5)
```

The base is `~/.loom` (or `LOOM_HOME`), not `priv/`, because a deploy replaces
`priv/`.

There is no message log. The conversation belongs to the backend: CC keeps it
in `~/.claude/projects/…`, Codex in its thread store. `events.jsonl` is only
the display truth, and it may legitimately differ from the backend's history.
For example, text streamed before an interrupt is shown but dropped by the
backend. **Never reconcile one against the other.**

> **Gotcha:** `Store.read_meta/1` uses `String.to_existing_atom/1` and falls
> back to string keys. An adapter atom may not exist yet at boot, so adapters
> read meta through `Backend.meta_get/2`, which accepts both.

### 4.1 Attachments

Attachments are uploaded over HTTP (multipart), not the channel, so a 20 MB
screenshot doesn't block every event behind it. The model gets an absolute path
and reads the file with its own tools: CC's `Read`, Codex's `view_image`. There
is no base64 and no multimodal content block.

- **The displayed text is not what the model gets.** The user's text and the
  attachment list are stored separately. Only the copy sent to the backend
  carries the paths.
- **Files show as small cards**, the same in the composer, in a sent bubble
  and for a download: an image shows a thumbnail, anything else its extension
  and name. The thumbnail of an attachment you just added comes from the local
  copy. Otherwise it is fetched with the token, from
  `GET /api/agents/:id/files/:name` or the output route, and cached for the
  page.
- **A path is a capability.** `Files.verify/2` rejects anything outside this
  session's `files/`, and file names are treated as hostile.

### 4.2 Output

Output is the reverse of attachments. The backend's system prompt names the
session's `output/` directory: CC via `--append-system-prompt`, Codex via
`developerInstructions`. At every turn end (done, failed or interrupted) Loom
diffs that directory against a snapshot and emits `:output_files` before
`turn_done`. The frontend shows a download card whether or not the model
linked the file.

The card shows one entry per top-level name in `output/`. A file directly in
`output/` is one card. A directory is also one card, however many files
changed in it; a comic chapter of forty pages is one card, not forty. A
directory with an `index.html` is a page; any other directory downloads as a
zip (`GET /api/agents/:id/zip/*path`), stored uncompressed and capped at 1 GB.

Downloads need the bearer token. The frontend therefore fetches the file as a
blob rather than using `<a href>`. `Output.resolve/2` refuses paths outside
`output/` and any symlink along the way.

### 4.3 Canvas

The canvas is a browser pane for `output/`. It shares the right-hand column
with the terminals and shows one of the two at a time. Clicking a previewable
output (a page, an image, a video, a PDF, text or code) shows it there, and the
canvas has its own download button. Anything else downloads on click. What
each session's canvas shows is kept per session, so switching to the terminals,
to another session, or reloading the page finds it as it was. Only one thing
opens the canvas without a click: a turn ending with a new or changed
`index.html`. That page is `open` in the `:output_files` event, and only a live
event acts on it, never history replayed on join. The agent is told the
convention in its system prompt: `output/<name>/index.html` with assets beside
it, referenced by relative paths.

The page is model output, so it is treated as hostile:

- It runs in `<iframe sandbox="allow-scripts …">` without `allow-same-origin`,
  so it has an opaque origin and cannot reach loom's token or API. The server
  sends the same sandbox as a CSP header on every response, so a canvas URL
  opened in a tab of its own is just as confined.
- An iframe cannot send the bearer header, so the files are served under a
  signed, session-scoped prefix, `/canvas/<id>/<token>/`, valid for a day. The
  token is in the path, so the page's own relative URLs inherit it.
  `Referrer-Policy: no-referrer` keeps the token from being sent to the CDNs a
  page loads from.
- Logs, data and source files are sent as `text/plain`, so they display
  instead of downloading.

## 5. A session's backend is for life

`POST /api/agents` without a `backend` returns 422; there is no default. The
history lives in the backend's own store, so switching backends would lose it.
Titles exist only on Loom's side and are never sent to the backend.

## 6. Supervision tree

```
Loom.Supervisor
├─ Phoenix.PubSub
├─ Registry + DynamicSupervisor   Loom.Terminal.Session (PTYs)
├─ Loom.Terminal.Layout
├─ Registry + DynamicSupervisor   Loom.Agent.Session (max_restarts 20/5s)
├─ Task.Supervisor
├─ Loom.Agent.Codex.Server        the one shared codex app-server
├─ Loom.Agent.Bootstrap           reattaches persisted sessions at boot
├─ Loom.Cron                      scheduled prompts
├─ Loom.Restarter                 restart-when-idle, for deploys
└─ LoomWeb.Endpoint
```

`Codex.Server` respawns its OS process itself, with backoff. A `codex` that
fails instantly would otherwise crash-loop a permanent child and take the
application down with it.

## 7. Terminals

Each `Loom.Terminal.Session` owns one PTY (`expty`). Terminals are global, not
tied to an agent session.

- **Several clients, one shell.** Every client gets the output, and input is
  serialized through the GenServer mailbox. The buffer is replayed inside
  `subscribe/3`, so no output can slip in between "fetch buffer" and
  "subscribe".
- **The size follows whoever typed last** (tmux's `window-size latest`). A
  resize from a client that is only watching is stored but not applied.
- **A non-driver's terminal replies are dropped.** These are cursor reports,
  DA, OSC, DCS, focus events and similar answers that xterm sends on its own.
  Without this, two browsers would both answer the same query.

## 8. Frontend

```
App.tsx           layout: sidebar | chat | terminals or canvas (drawer + overlay on phones)
Canvas.tsx        the canvas pane; canvasItems.ts decides what opens there
Sidebar.tsx       session list, new-session menu
Chat.tsx          timeline, tool cards, queue, composer
agent.ts          pure reducers: applySnapshot / applyEvent / applyDelta / buildTimeline / foldFinished
markdown.tsx      markdown for assistant messages only
Terminal.tsx      one xterm pane
useAgent.ts       one agent channel's lifecycle
```

- **All transcript rules live in `agent.ts`**, as pure functions. When a turn
  is finished, `foldFinished` collapses its consecutive tool calls into one
  "used N tools" card.
- **Channel params are a function**, so every rejoin asks for the gap since the
  last `seq` actually seen.
- **The queue is never derived from events.** The server's `:queue` event
  carries the full list.
- **Markdown is rendered from `marked.lexer()` tokens into React elements**,
  never through HTML. Model output can contain anything from a fetched page,
  and this way it cannot become markup. Raw `html` tokens render as text,
  `javascript:` links are inert, and images are not loaded.
- **IME:** check both `isComposing` and a `compositionend` flag. Chrome and
  Safari order those events differently.

### 8.1 Debugging: record and replay

```sh
pnpm transcript record <session-id> "prompt" [--attach a.png]
pnpm transcript replay <file.json> [--steps]
pnpm transcript check  <file.json>
```

`tools/transcript.mjs` imports `src/agent.ts` directly. It separates "the data
is wrong" (duplicate deltas, `block_id` collisions) from "the data is fine, so
it's CSS".

## 9. Not done

- `:question` events (CC `AskUserQuestion`, Codex `requestUserInput`). Today a
  question arrives as plain text.
- Turns that survive a Loom restart (a Codex daemon mode).
- Cleanup of uploads that were removed from the tray.
- Range requests on the canvas, so a long video can seek, and a proper video
  player. Markdown in the canvas shows as plain text, the way a browser shows
  it.
