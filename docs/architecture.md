# Architecture

Loom is a single-user lobby for cloud agents. Every device connects to the same
session; state lives on the server and on disk; the agent is Claude Code,
Codex or Kiro. Protocol details are in [backends.md](backends.md), deployment in
[deploy.md](deploy.md).

## 1. Non-goals

- **Multi-tenancy.** One password, one token for every device. Agents run as
  the BEAM's uid, with no sandbox.
- **Permission prompts.** Everything runs in auto mode; nobody is there to
  press `y`.
- **Our own agent loop.** Tools, context, compaction and memory belong to the
  backend ([backends.md §1](backends.md)).
- **A per-session working directory.** Every session starts in `$HOME` (or
  `LOOM_WORKSPACE`). The project is a fact in the conversation, not config.

## 2. One session, one GenServer

```
Loom.Agent.Session        one process per session, restart: :transient
  ├─ Loom.Agent.Backend   adapter behaviour (ClaudeCode, Codex, Kiro)
  ├─ Loom.Agent.Store     meta.json + events.jsonl
  └─ PubSub "agent:<id>"  events and deltas
```

Failures and turn state are per-session, so one bad response cannot take other
transcripts down. The process holds no sockets: a turn finishes with every
browser closed.

### 2.1 States

```
:idle ─submit→ :starting ─backend up→ :running ─turn ends→ :idle
                                         │ interrupt
                                         ↓
                                   :interrupted ─submit→ :starting
```

`:starting` covers the backend's cold start. `:interrupted` only suppresses
"idle with a queue → dequeue": after a stop nothing moves until the user types,
and the parked messages go out with the new one.

### 2.2 Submit

| State | Action | Returns |
|---|---|---|
| `:idle` | start a turn | `:started` |
| `:starting` / `:running` | steer into the current turn | `:steered` |
| steer rejected | queue | `:queued` |
| `:interrupted` | queue + new message, start a turn | `:started` |

Both backends inject mid-turn natively. The queue holds only messages typed
while interrupted and rejected steers (Codex's `expectedTurnId` mismatch); it
is persisted.

### 2.3 Crash recovery

A restarted session finds `meta.json` and reattaches; disk wins over the spec.
A crash mid-turn counts as an interrupt: resending would show the model the
message twice. The session comes back `:interrupted`, queue kept, with a status
event saying why.

### 2.4 `/reload` and `/cron`

Loom's own commands, never sent to a backend; only a message that is exactly
the command counts. `/reload` tells every session to let its backend process
go, now if idle or at turn end, so the next turn is a fresh `claude --resume`
with new settings, MCP servers and skills. The shared Codex app-server restarts
once no Codex turn is running and reattaches threads silently
([backends.md §6.11](backends.md)). `/cron` lists the jobs (§2.5).

### 2.5 Scheduled prompts

`Loom.Cron` submits a fixed prompt to an existing session at every match of a
five-field cron expression, in UTC. It is an ordinary turn (`origin: "cron"`),
so its reply and outputs land in the session; a busy session steers or queues
it.

- `~/.loom/cron.json` is the truth, read at boot, rewritten on change;
  `next_at` is never stored. Minutes missed while down are skipped.
- No HTTP API. Jobs are made with `bin/loom rpc` (`Loom.Cron.add/list/delete`),
  the prompt in a `~S"""` heredoc so it arrives verbatim. The `cron` skill
  tells agents how.

### 2.6 Notifications

`Loom.Push` sends Web Push to every subscribed device when a turn ends with
nothing queued: the title and the start of the reply or error. An interrupt
sends nothing; tapping opens the session.

- **No account.** The VAPID pair is made on first boot and kept in
  `~/.loom/push.json` with the subscriptions; encryption and signing are
  `:crypto`. Losing the file orphans every device.
- **The session broadcasts, Push decides.** A session only announces
  `{:turn_ended, id, summary}` on `Loom.Agent.turns_topic/0`.
- **Not to a device that is looking.** Each device tells the lobby channel
  which session it shows (`nil` when hidden), held against the channel's pid.
- **Declarative payload** (`web_push: 8030`), shown by Safari 18.4+ without the
  service worker; elsewhere `frontend/public/sw.js` shows it. The worker
  caches nothing.
- iPhone: home-screen app only (iOS 16.4+). A 404/410 from the push service
  drops the subscription.

### 2.7 What the backend is told

A session's backend is fixed at creation: `POST /api/agents` without
`backend` is 422, since the history lives in the backend's own store. Titles
stay on Loom's side.

Every spawn's system prompt (CC `--append-system-prompt`, Codex
`developerInstructions`, Kiro `_meta.kiro.steering`,
[backends.md §9](backends.md)), from `Loom.Agent.Instructions`, one text per
backend, says, in order:
that it runs inside Loom, how Loom is built and where its source is; the
session's id and directory; its lifetime: Loom lets an idle backend go and
restarts on deploys, so background jobs, subagents and timers die with the
turn, and subagents run in the foreground even when a plugin says otherwise,
work meant to outlive it going through Loom (the `sessions` and `cron`
skills); how many images to read directly before handing them to
subagents, since a request is capped at about 32 MB; and the `output/` directory and canvas convention.

## 3. Client protocol

```
event  has a seq, persisted to events.jsonl, replayed on reconnect. The truth.
delta  no seq, transient, never replayed. The typewriter.
```

Deltas (`:block_start`, `:block_end`, `:text`, `:thinking`, `:tool_use_start`,
`:tool_output`) append to a placeholder keyed by `block_id`; the event with the
same `block_id` replaces it whole, so a stream cut mid-sentence costs nothing.

- **Loom owns `seq`.** The session is the only writer of `events.jsonl`;
  backend ids go in `backend_ref`, for dedup on reattach.
- **Multiple devices.** A client joins with the last `seq` it saw and gets the
  gap. PubSub fans out; the channel holds no state.
- **Session list** is pushed on the `agents` lobby channel, ordered by
  `last_active_at` (last user message, reply or turn end, derived from the
  transcript on restore). Devices, apps and search ride the same channel.

## 4. Storage

```
~/.loom/sessions/<id>/meta.json      header, rewritten atomically (temp + rename)
~/.loom/sessions/<id>/events.jsonl   normalized transcript, append-only, :sync
~/.loom/sessions/<id>/files/…        user attachments
~/.loom/sessions/<id>/output/…       files the agent made for the user
~/.loom/sessions/.trash/<id>.<ms>/   a deleted session, kept whole
~/.loom/cron.json  push.json  apps.json  apps/<name>/
~/.loom/backends/kiro.json           Kiro's model/effort/args/env (Loom.Agent.BackendConfig)
```

The base is `~/.loom` (or `LOOM_HOME`), not `priv/`, which a deploy replaces.
Deleting a session is a rename into `.trash`; nothing is ever removed, and an
id that is not one plain path segment is refused.

There is no message log. The conversation belongs to the backend (CC's
`~/.claude/projects/…`, Codex's thread store, Kiro's `~/.kiro/sessions`); `events.jsonl` is only the
display truth and may legitimately differ, e.g. text streamed before an
interrupt. **Never reconcile one against the other.**

> **Gotcha:** `Store.read_meta/1` uses `String.to_existing_atom/1` and falls
> back to string keys, so adapters read meta through `Backend.meta_get/2`.

### 4.1 Attachments

Uploaded over HTTP multipart, not the channel. The model gets an absolute path
and reads it with its own tools; no base64, no multimodal blocks. The text
shown and the paths sent to the backend are stored separately.

- **Scaled in the browser** (`shrink.ts`) to 2000 px on the long edge, about
  what CC and Codex do anyway, which matters on a phone uplink and against
  Bedrock's ~32 MB request cap. Format kept (HEIC → JPEG), JPEG EXIF kept with
  orientation 1. Files that would not shrink, GIF and SVG go up untouched.
- **A path is a capability.** `Files.verify/2` rejects anything outside this
  session's `files/`; names are treated as hostile.

### 4.2 Output

At every turn end Loom diffs `output/` against a snapshot and emits
`:output_files` before `turn_done`, so a download card appears whether or not
the model linked the file. One card per top-level name: a directory with
`index.html` is a page, any other directory a zip (stored, capped at 1 GB).
Downloads need the bearer token, so they are fetched as blobs.
`Output.resolve/2` refuses paths outside `output/` and any symlink.

### 4.3 Canvas

The canvas shows `output/` in the right-hand column, which it shares with the
terminals. Clicking a previewable output (page, image, video, PDF, text, code)
shows it; anything else downloads. The view is kept per session. Only one
thing opens it unasked: a live turn end with a new or changed `index.html`.

Beside the view, NERDTree-style, is a file tree of the whole session
(`output/` and `files/`, newest first, `GET /api/agents/:id/tree`), refreshed on
live `:output_files` and `user` events, never polled. A file rewritten in place
is reread when opened or named by a live event. From the keyboard a row can be
renamed or deleted (`PATCH`/`DELETE …/output/*path`, `…/files/:name`; 409 for a
taken name, 422 for one that would move it).

The page is model output, so it is hostile:

- `<iframe sandbox="allow-scripts …">` without `allow-same-origin`, and the
  same sandbox as a CSP header, so a canvas URL in its own tab is as confined.
- Files are served under a signed, session-scoped `/canvas/<id>/<token>/`,
  valid a day; relative URLs inherit the token. `Referrer-Policy: no-referrer`
  keeps it from CDNs. `Cache-Control: no-transform` stops Cloudflare injecting
  its beacon.
- Logs, data and source are sent as `text/plain`.

### 4.4 Devices (loom-node)

Each device runs `loom-node daemon`, the Go program in `node/`; the same binary
is the CLI agents call here.

```
agent ──zsh──> loom-node exec mac -- '…'      CLI, on this host
                 │  HTTP on loom's own port, NDJSON stream
                 ▼
          NodeController ── Loom.Nodes (who is registered / online)
                 │  Erlang messages
                 ▼
          NodeChannel  ◄── wss /node/websocket, through cloudflared ──  loom-node daemon (device)
```

- **Registering.** The Devices dialog returns a one-time install code (1 h).
  `curl …/node/install/<code> | sh` redeems it: mints the device token (kept as
  SHA-256, replacing any old one), downloads the binary for the OS/arch, writes
  `~/.config/loom-node/config.json`, installs a launchd or systemd user
  service. Removing the device revokes the token.
- **The CLI's routes** (`/api/node/*`) need the key in mode-600
  `~/.loom/node-cli.json`, and refuse anything carrying `cf-ray`.
- **Online** while the channel is alive; joins and drops are pushed.
- **Requests** (`exec`, `read`, `write`) carry an id through controller →
  channel → device and back. The controller pings the CLI every second and
  cancels on the device when the CLI is gone; an offline device gets 10 s to
  reconnect.
- **Losing the device.** The CLI exits 255 (`lost`). The device kills what it
  was running when its connection drops (or heartbeats go unanswered 15 s);
  the server drops a silent socket after 45 s.
- **Commands** run as `$SHELL -lc` in their own process group, stdin closed,
  timeout 120 s (max 1800 s, exit 124), output capped at 10 MB. Writes go to a
  temp file renamed into place. Everything is logged on the device in
  `~/.local/state/loom-node/log`.

## 5. Apps

An app is work an agent distilled out of a conversation into a plain program,
so using it costs no tokens: `~/.loom/apps/<name>/` with

- `web/` — the page, its favicon the icon;
- `server` — optional command listening on the unix socket `$APP_SOCKET`, or
  on `$PORT` when the app declares a `port`;
- `job` — optional command run on `schedule` (systemd `OnCalendar`, UTC).

`proxy` says what the server gets: `"api"` (default) only `api/*`, `web/`
being the rest; `"all"` every request, for a whole site such as one cloned
from elsewhere, which then needs no `web/`.

**Loom is the registry, not the data plane.** `Loom.Apps` is one GenServer
over `~/.loom/apps.json` (title, order, proxy, port, server, idle, job,
schedule), pushed whole on the lobby channel. From it, on every change and at
boot, it writes the units that run the apps and Caddy's config, and steps out
of the way: nothing an app serves passes through the BEAM, and the apps stay
up while Loom restarts. No HTTP API: agents use `bin/loom rpc` per the `apps`
skill. To hand work back to an agent, a program calls
`Loom.Agent.new_session_file/1` with title and prompt as JSON data, never
spliced into rpc code.

**systemd owns the processes.** Each app becomes user units:
`app-<name>.socket` holds `.run/http.sock`; the first connection starts a
`systemd-socket-proxyd` that exits after `idle` and takes the server with it,
and is bound to it, so a server that dies takes the proxy along and the next
connection starts both afresh. `app-<name>_job.timer` is `Persistent`, so a
run missed while down happens at boot. Suffixes are joined with `_`, which a
name cannot hold, so `x`'s units never collide with an app called `x-job`.
Loom never tracks a pid. At boot every app's units are rewritten, any other
`app-*` unit removed, and a running proxy whose unit changed stopped.

**Caddy serves them**, as the user unit `loom-apps.service`, on
`LOOM_BIND:LOOM_APPS_PORT` (5000) behind the apps' own origin
(`LOOM_APPS_URL`; unset, `http://localhost:5000`), never Loom's.
`~/.loom/caddy.json` is its whole config, generated, written before it is
loaded with `caddy reload` over the admin socket `~/.loom/caddy-admin.sock`
(0600), so a Caddy started later starts from what is current.

- Each app is `/apps/<name>/`: `web/` as files, the server behind
  `reverse_proxy` (HTTP/2, WebSocket and SSE as they are). An `"api"` app's
  server sees `/api/…`; an `"all"` app's sees the full path, with
  `X-Forwarded-Prefix`.
- A reply with `x-loom-file: <path>` (absolute, or relative to the app's
  directory; URL-encoded) is answered with that file from disk, with Range,
  like `X-Accel-Redirect`; iOS needs Range to play video. Anything outside
  the app's directory is a 404.
- `/vendor/` is Loom's bundled libraries (reveal.js, KaTeX), so a deck copied
  into an app works.
- `Cache-Control: no-cache, no-transform` unless the app sets its own.

**No access control.** An app is open to whoever reaches the apps' origin; one
that must know who is asking checks for itself. All apps share the origin, so
they can read each other's storage and cookies unless scoped by path.

The Apps grid in the sidebar is a home screen of icons; an app opens in the
main pane.

## 6. Browser

An optional Chromium on Xvfb (`rel/browser/`, a systemd unit and an AppArmor
profile so it keeps its sandbox): Google Chrome if installed, else
Playwright's Chromium. Its profile persists, so sites stay logged in.
Everything is on loopback: agents drive it over CDP on `127.0.0.1:9222`, and
the Browser pane is noVNC over `/browser/vnc`, which checks the login token and
bridges to x11vnc (`LoomWeb.VncSocket`). On a phone it shows 1:1 with drag to
pan and a field to type into the page. The `browser` skill says to use an own
tab and when to hand over to the user.

## 7. Supervision tree

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
├─ Loom.Nodes                     the user's devices (loom-node)
├─ Loom.Apps                      apps registry; writes their units and Caddy's config
├─ Loom.Push                      notifications when a turn ends
├─ Loom.Restarter                 restart-when-idle, for deploys
└─ LoomWeb.Endpoint
```

`Codex.Server` respawns its OS process itself, with backoff, so a `codex` that
fails instantly cannot crash-loop the application. `loom.service` sets
`OOMPolicy=continue`: an OOM kill takes its victim, not every session.

Skills ship in the repo (`skills/*/SKILL.md`, `node/SKILL.md`) and
`rel/deploy.sh` copies them into both backends' skill directories. They hold
platform facts only.

## 8. Terminals

Each `Loom.Terminal.Session` owns one PTY (`expty`); terminals are global, not
tied to a session.

- **Several clients, one shell.** Input is serialized through the mailbox; the
  buffer is replayed inside `subscribe/3`, so nothing slips in between.
- **Size follows whoever typed last** (tmux `window-size latest`).
- **Only the driver's terminal replies** (cursor reports, DA, OSC, DCS, focus)
  pass; otherwise two browsers answer the same query.

## 9. Frontend

```
App.tsx           layout: sidebar | chat | terminals, canvas or browser (drawer + overlay on phones)
Sidebar.tsx       New chat, Directories (folding) and Recents; Apps, Browser, Devices, Settings at the foot
directories.ts    directories derived from the sessions' prefixes, in the shared order
useDragOrder.ts   dragging the directories into that order
MovePicker.tsx    "Move to directory": the row menu's submenu, or nearly full screen on a phone
RowMenu.tsx       a row's "…" menu, drawn on the body, with submenus
Search.tsx        ␣␣: titles fuzzy-matched here (fuzzy.ts), transcripts by rg on the server
Chat.tsx          timeline, tool cards, queue, composer (draft per session)
Canvas.tsx        the canvas; canvasItems.ts decides what opens there; FileBrowser.tsx the tree
Apps.tsx          the Apps grid and an open app
Browser.tsx       noVNC pane
agent.ts          pure reducers: applySnapshot / applyEvent / applyDelta / buildTimeline / foldFinished
markdown.tsx      markdown for assistant messages only
Terminal.tsx      one xterm pane
push.ts theme.ts  this device's notifications and theme (Settings.tsx)
keys.tsx          vim-style keys, desktop only, off by default (docs/keys.md)
ime.ts            whether a key event belongs to an IME composition
useAgent.ts       one agent channel; useLobby.ts the lobby
```

- **Directories are S3 prefixes.** A session's header carries `directory`
  (`""` for the root); a directory exists while some session is in it.
  Moving or renaming rewrites each session's prefix
  (`Loom.Agent.move_directory/2`); ids and on-disk paths never change. The
  sidebar keeps them one level deep (a new name has no `/`; an older deeper
  path is listed whole). Which are unfolded, and whether the section is open,
  is per device in localStorage. Their order is shared: dragged into place
  (`useDragOrder`, pointer events; a finger holds still first), the whole list
  goes over the lobby channel to `Loom.Agent.DirectoryOrder`
  (`~/.loom/directories.json`), which pushes it to every device. It is only a
  sort key — a directory not in it goes last, in code point order — and a
  rename carries its entry along. The sessions inside a directory go by
  activity.
- **Search is two searches.** Titles are matched fuzzily on every keystroke as
  `directory/title`, a title match ranking above a directory-only one.
  Transcripts are searched by ripgrep (`Loom.Search`, over the lobby channel)
  200 ms after the last keystroke, never mid-composition; user messages and
  replies only, and a newer search kills the running one. Without `rg` it says
  titles only.
- **All transcript rules live in `agent.ts`**, as pure functions.
  `foldFinished` collapses a finished turn's tool calls into "used N tools".
- **Channel params are a function**, so every rejoin asks for the gap since
  the last `seq` seen. The queue comes whole in `:queue`, never derived.
- **Markdown is rendered from `marked.lexer()` tokens into React elements**,
  never HTML: raw `html` renders as text, `javascript:` links are inert,
  images are not loaded.
- **IME** (`ime.ts`): `isComposing`, a `compositionend` flag, and keyCode 229.
  Safari fires `compositionend` before the keydown that commits, so only 229
  tells that Enter was the IME's.
- **Theme** light / dark / system per device, set on `<html>` before paint;
  colors are CSS variables.

### 9.1 Debugging: record and replay

```sh
pnpm transcript record <session-id> "prompt" [--attach a.png]
pnpm transcript replay <file.json> [--steps]
pnpm transcript check  <file.json>
```

`tools/transcript.mjs` imports `src/agent.ts` directly, separating "the data is
wrong" (duplicate deltas, `block_id` collisions) from "it's CSS".

## 10. Not done

- `:question` events (CC `AskUserQuestion`, Codex `requestUserInput`); a
  question arrives as plain text.
- Turns that survive a Loom restart (a Codex daemon mode).
- Cleanup of uploads removed from the tray, and of the trash.
- Range requests on the canvas, so a long video can seek. Markdown in the
  canvas shows as plain text.
