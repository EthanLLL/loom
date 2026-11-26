# Architecture

Loom is a single-user lobby for cloud agents. Every device connects to the same
session; state lives on the server and on disk; the agent is Claude Code,
Codex or Kiro. Protocol details are in [backends.md](backends.md), deployment in
[deploy.md](deploy.md). This document covers the server.

## 1. Non-goals

- **Multi-tenancy.** One user, signed in per device (§3.1). Agents run as the
  BEAM's uid, with no sandbox.
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

All three backends take a message mid-turn: Claude Code at the next
tool-result boundary, Codex by `turn/steer`, Kiro by `_session/steer`; a
message typed while Kiro is still booting is merged into the prompt it has
not yet sent. The queue holds only messages typed while interrupted and
rejected steers (Codex's `expectedTurnId` mismatch, or no Kiro turn to
steer); it is persisted.

### 2.3 Crash recovery

A restarted session finds `meta.json` and reattaches; disk wins over the spec.
A crash mid-turn counts as an interrupt: resending would show the model the
message twice. The session comes back `:interrupted`, queue kept, with a status
event saying why.

### 2.4 Idle release, `/reload` and `/cron`

A Claude Code process is ~275 MB, a Kiro one ~500 MB, so each session lets its
backend process go after `LOOM_IDLE_RELEASE_MINUTES` (default 5) with no turn;
the next turn pays a cold start of about 4 s. The conversation is unaffected,
being in the backend's own store. For Codex, whose app-server is shared, it is
a no-op.

`/reload` and `/cron` are Loom's own commands, never sent to a backend; only a
message that is exactly the command counts. `/reload` tells every session to
let its backend process go, now if idle or at turn end, so the next turn is a
fresh `claude --resume` (or `session/load` in a fresh `kiro-cli acp`) with new
settings, MCP servers and skills. The shared Codex app-server restarts once no
Codex turn is running and reattaches threads silently
([backends.md §2](backends.md)). `/cron` lists the jobs (§2.5).

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
- iPhone: home-screen web app only (iOS 16.4+). A 404/410 from the push
  service drops the subscription.
- **APNs.** A native client may sign up with an APNs device token instead,
  sent to through Apple (`Loom.Push.APNs`, HTTP/2 through Mint) when the
  server has a key (`LOOM_APNS_*`). Its endpoint is Apple's URL for the
  token, so it is watched and dropped like a Web Push one; a
  `BadDeviceToken` drops it too.

### 2.7 What the backend is told

A session's backend is fixed at creation: `POST /api/agents` without
`backend` is 422, since the history lives in the backend's own store. Titles
stay on Loom's side.

- **Model, per session.** Switchable at any time (`PATCH /api/agents/:id` with
  `model`), from the next turn on; it must be one of the backend's own list
  (`GET /api/models?backend=…`, with `&profile=…` for a session on one), else
  422. It is kept in the header and
  announced in the transcript (`:model_changed`). No fallback model, so who
  answered is always visible. A new Kiro session starts on `LOOM_KIRO_MODEL`
  (unset, `auto`).
- **Profiles.** Another provider or key for one session, fixed at creation
  like the backend (`profile` on `POST /api/agents`); `GET /api/profiles`
  lists them with their backend. `$LOOM_HOME/profiles/claude_code/<name>.json`
  is a Claude Code settings file, passed as `--settings` on every spawn.
  `$LOOM_HOME/profiles/codex/<name>.json` is an OpenAI-compatible endpoint, its
  key and the models a session on it may pick, sent with every thread start
  and resume. The header records only the name, so the key never enters it
  and an edit applies at the next spawn or resume.

Every spawn's system prompt (CC `--append-system-prompt`, Codex
`developerInstructions`, Kiro a per-session agent file,
[backends.md §4](backends.md)), from `Loom.Agent.Instructions`, one text per
backend, says, in order:
that it runs inside Loom, how Loom is built and where its source is; the
session's id and directory; its lifetime: Loom lets an idle backend go and
restarts on deploys, so background jobs, subagents and timers die with the
turn, and subagents run in the foreground even when a plugin says otherwise,
work meant to outlive it going through Loom (the `sessions` and `cron`
skills); how to read many images; for Kiro, that its MCP config is changed
with `kiro-cli mcp`, not by writing files; and the `output/` directory and
canvas convention.

The image guidance differs. Claude Code is told a request is capped at about
32 MB and every image read rides along in every later one: up to 20 in total
it reads them directly, beyond that (or 5 or more in one message) it hands
them to foreground `sonnet` subagents that transcribe them into
`files/transcripts/`, and past 40 it asks the user to `/compact`. Codex and
Kiro are only told to write down what each image shows as they go and work
from those notes.

## 3. Client protocol

```
event  has a seq, persisted to events.jsonl, replayed on reconnect. The truth.
delta  no seq, transient, never replayed. The typewriter.
```

Deltas (`:block_start`, `:block_end`, `:text`, `:thinking`, `:tool_use_start`,
`:tool_output`) append to a placeholder keyed by `block_id`; the event with the
same `block_id` replaces it whole, so a stream cut mid-sentence costs nothing.
Deltas carry their own `delta_seq`, so a client can drop one it has already
applied.

- **Loom owns `seq`.** The session is the only writer of `events.jsonl`;
  backend ids go in `backend_ref`, for dedup on reattach.
- **Multiple devices.** A client joins `agent:<id>` with the last `seq` it saw
  and gets the gap. PubSub fans out; the channel holds no state. The queue is
  sent whole as `:queue`.
- **Session list** is pushed on the `agents` lobby channel, ordered by
  `last_active_at` (last user message, reply or turn end, derived from the
  transcript on restore). Devices, apps, the directory order and search ride
  the same channel.
- **Directories are S3 prefixes.** A session's header carries `directory`
  (`""` for the root); a directory exists while some session is in it.
  Moving or renaming rewrites each session's prefix
  (`Loom.Agent.move_directory/2`, `POST /api/directories/move`); ids and
  on-disk paths never change. Their order is shared:
  `Loom.Agent.DirectoryOrder` keeps the list a client sends over the lobby
  channel in `~/.loom/directories.json` and pushes it to every device. It is
  only a sort key — a directory not in it goes last, in code point order — and
  a rename carries its entry along.
- **Search.** Transcripts are searched by ripgrep (`Loom.Search`, `search`
  on the lobby channel): user messages and replies only, the match checked
  again in the decoded text, and a newer search from the same client kills
  the running one. Without `rg` it says so and the client matches titles
  only.

### 3.1 Signing in

Whoever is signed in has a shell, so the door is guarded (`Loom.Auth`):

- **Two ways in.** A passkey — Face ID, Touch ID, Windows Hello, or a phone
  nearby — or `LOOM_PASSWORD` plus a code from an authenticator app (TOTP) or
  one of eight one-time recovery codes. The password alone works only until an
  authenticator is set up, so the first device can get in to set one up.
- **WebAuthn without CBOR.** The browser hands over the new key's SPKI
  (`getPublicKey()`) and the authenticator data, so `:crypto` is enough;
  attestation is not checked (registering needs a signed-in device). The RP
  id is the origin's host, kept with the passkey.
- **A login per device**, named from its user agent; the bearer token names
  it. Removing one (`DELETE /api/auth/logins/:id`) drops its socket
  (`login:<id>`); two weeks unused lapses it. Tokens from before logins work
  while the password alone does, and are swapped for a login on the next
  open.
- Five wrong passwords or codes lock the password way in for 15 minutes (in
  memory; passkeys do not count); a new sign-in is announced to every device
  with notifications on.

### 3.2 HTTP API

Everything under `/api` but sign-in needs the bearer token
(`LoomWeb.Plugs.RequireAuth`). The channels on `/socket` (`agents`,
`agent:<id>`, `terminal:<id>`) check it in `connect/2`.

```
/api/login, /api/auth/options, /api/auth/passkey/*      signing in
/api/auth, /api/auth/passkeys, /api/auth/totp, …/logins  managing it
/api/agents[/:id]            list, create, PATCH title/directory/model, delete
/api/profiles, /api/models   what a new session or a switch may name
/api/directories/move        rename or move a directory
/api/agents/:id/files…       attachments: upload, read, rename, delete
/api/agents/:id/output/*, …/zip/*, …/tree, …/canvas      output and canvas
/api/sessions[/:id]          terminals; /api/layout their tabs and panes
/api/devices[/:id]           devices, install codes, …/rtc offers
/api/push…                   Web Push key and subscriptions
/api/node/*                  the loom-node CLI on this host (§4.4)
/node/install/:code, /node/download/:target              device install
/canvas/…, /canvas-files/…, /app-icons/…, /browser/vnc, /devices/:id/port/:port
```

## 4. Storage

```
~/.loom/sessions/<id>/meta.json      header, rewritten atomically (temp + rename)
~/.loom/sessions/<id>/events.jsonl   normalized transcript, append-only, :sync
~/.loom/sessions/<id>/files/…        user attachments
~/.loom/sessions/<id>/output/…       files the agent made for the user
~/.loom/sessions/.trash/<id>.<ms>/   a deleted session, kept whole
~/.loom/auth.json                    passkeys, authenticator secret, logins (0600)
~/.loom/cron.json  push.json         scheduled prompts; VAPID pair and subscriptions
~/.loom/directories.json             the shared directory order
~/.loom/nodes.json  node-cli.json    devices and their token hashes; the CLI's key (0600)
~/.loom/profiles/<backend>/<name>.json  Claude Code and Codex profiles
~/.loom/apps.json  apps/<name>/      the apps registry; each app's directory
~/.loom/apps/.trash/<name>-<s>/      a removed app
~/.loom/app-icons/<name>/<hash>.<ext>  Loom's copy of each app's icon
~/.loom/caddy.json  caddy-admin.sock   Caddy's generated config; its admin socket (0600)
~/.kiro/agents/loom-<id>.md          a Kiro session's instructions and permissions
```

The base is `~/.loom` (or `LOOM_HOME`), not `priv/`, which a deploy replaces.
Deleting a session is a rename into `.trash`; nothing is ever removed, and an
id that is not one plain path segment is refused. The request returns once the
header says `deleting` and the session is off every list; the process then
stops its backend and makes the move as it exits, and a restart in between
finishes it.

There is no message log. The conversation belongs to the backend (CC's
`~/.claude/projects/…`, Codex's thread store, Kiro's `~/.kiro/sessions`);
`events.jsonl` is only the display truth and may legitimately differ, e.g.
text streamed before an interrupt. **Never reconcile one against the other.**

> **Gotcha:** `Store.read_meta/1` uses `String.to_existing_atom/1` and falls
> back to string keys, so adapters read meta through `Backend.meta_get/2`.

### 4.1 Attachments

Uploaded over HTTP multipart, not the channel. The model gets an absolute path
and reads it with its own tools; no base64, no multimodal blocks. The text
shown and the paths sent to the backend are stored separately.

- **Scaled by the client** to 2000 px on the long edge before upload, about
  what CC and Codex do anyway, which matters on a phone uplink and against
  Bedrock's ~32 MB request cap.
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

The canvas shows a session's files beside the chat. Only one thing opens it
unasked: a live turn end with a new or changed `index.html`.

`GET /api/agents/:id/tree` lists the whole session (`output/` and `files/`,
newest first); clients refresh it on live `:output_files` and `user` events,
never by polling. Entries can be renamed or deleted (`PATCH`/`DELETE
…/output/*path`, `…/files/:name`; 409 for a taken name, 422 for one that
would move it).

The page is model output, so it is hostile:

- Served with `Content-Security-Policy: sandbox allow-scripts …` without
  `allow-same-origin`, so it gets an opaque origin in the client's sandboxed
  iframe and in a tab of its own alike. PDFs are the exception: Chrome will
  not start its PDF viewer in a sandboxed document, the viewer is the
  browser's own, and `nosniff` keeps a `.pdf` that is really HTML from
  running as a page.
- `POST /api/agents/:id/canvas` returns a signed, session-scoped prefix,
  valid a day: `/canvas/<id>/<token>/` for `output/` (relative URLs inherit
  the token; a directory means its `index.html`) and
  `/canvas-files/<id>/<token>/<name>` for attachments, under the same
  sandbox. `Referrer-Policy: no-referrer` keeps the token from CDNs;
  `Cache-Control: no-cache, no-transform` keeps intermediaries from rewriting
  the page.
- A single `Range: bytes=…` gets a 206, so video plays and seeks.
- Logs, data, markdown and source are sent as `text/plain`; the client
  renders markdown itself.

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
          NodeChannel  ◄── wss /node/websocket, through the proxy ──  loom-node daemon (device)
```

- **Registering.** The Devices dialog returns a one-time install code (1 h).
  `curl …/node/install/<code> | sh` redeems it: mints the device token (kept as
  SHA-256 in `nodes.json`, replacing any old one), downloads the binary for
  the OS/arch, writes `~/.config/loom-node/config.json`, installs a launchd or
  systemd user service. Removing the device revokes the token.
- **One device, several looms.** The config is a list of `{url, token}`; an
  install adds its loom or renews that loom's token and leaves the others, and
  the daemon keeps one connection per loom. `loom-node uninstall --url URL`
  drops one. The audit log on the device names the loom on every line. Agents
  of every loom listed run as the same user there.
- **The CLI's routes** (`/api/node/*`) need the key in mode-600
  `~/.loom/node-cli.json`, and refuse any request that came through the front
  proxy (`LoomWeb.Plugs.NodeCliAuth` checks for a header the proxy adds), key
  or not.
- **Online** while the channel is alive; joins and drops are pushed.
- **Requests** (`exec`, `read`, `write`) carry an id through controller →
  channel → device and back. The controller pings the CLI every second and
  sends `cancel` to the device when the CLI is gone; an offline device gets
  10 s to reconnect. `cancel {id}` ends whatever has that id: a command, a
  write, a PTY, a tunnel or a WebRTC peer.
- **Losing the device.** The CLI exits 255 (`lost`). The device kills what it
  was running when its connection drops (or a heartbeat, sent every 15 s,
  goes unanswered); the server drops a silent socket after 45 s.
- **Commands** run as `$SHELL -lc` in their own process group, stdin closed,
  timeout 120 s (max 1800 s, exit 124), output capped at 10 MB. Writes go to a
  temp file renamed into place. Everything is logged on the device in
  `~/.local/state/loom-node/log`.
- **Terminals** (`pty_open`, `pty_in`, `pty_resize`; back `pty_opened`,
  `pty_out`, `pty_exit`) are the user's, not the CLI's: the device runs its
  login shell on a PTY, and the terminal session on this side keeps the
  screen, §8. Like a command, the shell is hung up when the connection drops.
- **Screens** (Connect, offered for macOS devices only) are a port on the
  device's loopback: [loom-mac-screen](https://github.com/EthanLLL/loom-mac-screen)'s
  H.264 on 5960 if it answers, decoded in the browser with WebCodecs, or else
  VNC on 5900, macOS's Screen Sharing, drawn by noVNC. Direct when the
  networks allow: the browser's WebRTC offer goes to the device as
  `rtc_offer` (`POST /api/devices/:id/rtc`), its `rtc_answer` comes back with
  every candidate in it, and the two punch through on their own; a data
  channel labelled `tcp:<port>` is the line. No TURN server: when no path is
  found within seconds, the client falls back to `/devices/:id/port/:port`, a
  WebSocket that loom relays as `tcp_open`, `tcp_in`, `tcp_out`,
  `tcp_closed` (`LoomWeb.DevicePortSocket`). Loopback ports only, and they
  end with the connection like everything else.

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
over `~/.loom/apps.json` (name, title, order, proxy, port, server, idle,
memory, job, schedule, icon, created_at), pushed whole on the lobby channel.
From it, on every change and at boot, it writes the units that run the apps
and Caddy's config, and steps out of the way: nothing an app serves passes
through the BEAM, and the apps stay up while Loom restarts. No HTTP API:
agents use `bin/loom rpc` per the `apps` skill. Removing an app moves its
directory to `apps/.trash/`. To hand work back to an agent, a program calls
`Loom.Agent.new_session_file/1` with title and prompt as JSON data, never
spliced into rpc code.

**The grid is Loom's.** Opening the Apps grid must not start every app's
server to fetch an icon, nor show nothing for one that is down, so at each
`put` and at boot the app's favicon is copied to
`~/.loom/app-icons/<name>/<hash>.<ext>` and served from there at
`/app-icons/:name/:file`, under a name that changes with its bytes.

**systemd owns the processes.** Each app becomes user units:
`app-<name>.socket` holds `.run/http.sock`; the first connection starts a
`systemd-socket-proxyd` that exits after `idle` and takes the server with it,
and is bound to it, so a server that dies takes the proxy along and the next
connection starts both afresh. The server's memory cap is the app's `memory`
(default 256M). `app-<name>_job.timer` is `Persistent`, so a run missed while
down happens at boot. Suffixes are joined with `_`, which a name cannot hold,
so `x`'s units never collide with an app called `x-job`. Loom never tracks a
pid. At boot every app's units are rewritten, any other `app-*` unit removed,
and a running proxy whose unit changed stopped.

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
  like `X-Accel-Redirect`. Anything outside the app's directory is a 404.
- `/vendor/` is Loom's bundled libraries (reveal.js, KaTeX), so a deck copied
  into an app works.
- `Cache-Control: no-cache, no-transform` unless the app sets its own.

**No access control.** An app is open to whoever reaches the apps' origin; one
that must know who is asking checks for itself. All apps share the origin, so
they can read each other's storage and cookies unless scoped by path.

The Apps grid is a home screen of icons in the right-hand column; an app
opens there too, beside the chat.

## 6. Browser

An optional Chromium on Xvfb (`rel/browser/`, a systemd unit and an AppArmor
profile so it keeps its sandbox): Google Chrome if installed, else
Playwright's Chromium. Its profile persists, so sites stay logged in.
Everything is on loopback: agents drive it over CDP on `127.0.0.1:9222`, and
the client's Browser pane is noVNC over `/browser/vnc`, which checks the login
token and bridges to x11vnc (`LoomWeb.VncSocket`). The `browser` skill says to
use an own tab and when to hand over to the user.

It runs on demand: systemd holds `9222` and `5900` (`loom-browser-*.socket`),
the first connection to either starts the browser, and a
`systemd-socket-proxyd` per port passes it on to Chromium and x11vnc on `9223`
and `5901`. A proxy exits after 10 minutes without a connection; with both
gone the browser is stopped (`StopWhenUnneeded`), which gives back its
~400 MB. Open tabs go with it; the profile, and so the logins, stay. An open
Browser pane is a connection, so it keeps the browser up.

## 7. Supervision tree

```
Loom.Supervisor (one_for_one)
├─ LoomWeb.Telemetry
├─ Phoenix.PubSub
├─ Registry + DynamicSupervisor   Loom.Terminal.Session (PTYs)
├─ Loom.Terminal.Layout
├─ Registry + DynamicSupervisor   Loom.Agent.Session (max_restarts 20/5s)
├─ Task.Supervisor
├─ Loom.Agent.Codex.Server        the one shared codex app-server
├─ Loom.Agent.Bootstrap           reattaches persisted sessions at boot
├─ Loom.Cron                      scheduled prompts, after the sessions are back
├─ Loom.Agent.DirectoryOrder      the shared directory order
├─ Loom.Nodes                     the user's devices (loom-node)
├─ Loom.Apps                      apps registry; writes their units and Caddy's config
├─ Loom.Push                      notifications when a turn ends
├─ Loom.Auth                      passkeys, the authenticator, logins
├─ Loom.Restarter                 restart-when-idle, for deploys
└─ LoomWeb.Endpoint
```

`Codex.Server` respawns its OS process itself, with backoff, so a `codex` that
fails instantly cannot crash-loop the application. `loom.service` sets
`OOMPolicy=continue`: an OOM kill takes its victim, not every session.

Everything Loom spawns, agent CLIs and terminal shells, gets
`Loom.ChildEnv`: Loom's own variables (`SECRET_KEY_BASE`, `LOOM_PASSWORD`,
`PHX_SERVER`, `PORT`, `LOOM_HOME`, `LOOM_BIND`, the CLI overrides,
`RELEASE_*` …) dropped and the release's `erts-*/bin` and `bin` taken off
`PATH`; the rest passes through.

Skills ship in the repo (`skills/*/SKILL.md`, `node/SKILL.md`) and
`rel/deploy.sh` copies them into each backend's skill directory (`~/.claude`,
`~/.codex`, `~/.kiro`). They hold platform facts only.

## 8. Terminals

Each `Loom.Terminal.Session` owns one PTY (`expty`); terminals are global, not
tied to a session. Given a device (`POST /api/sessions` with `node`), the PTY
is on the device instead and its bytes cross that device's channel, §4.4;
everything below is the same. A device that drops leaves the terminal on
screen, saying so, until it is closed.

- **Several clients, one shell.** Input is serialized through the mailbox; the
  buffer is replayed inside `subscribe/3`, so nothing slips in between.
- **Size follows whoever typed last** (tmux `window-size latest`).
- **Only the driver's terminal replies** (cursor reports, DA, OSC, DCS, focus)
  pass; otherwise two browsers answer the same query.
- **Layout.** `Loom.Terminal.Layout` holds the tabs and their panes (one
  terminal each) in memory; `GET`/`PUT /api/layout` read and replace it,
  dropping panes whose shell has exited, so a reconnecting client restores
  the same arrangement. It does not survive a restart; neither do the PTYs.

## 9. Frontend

The client is a React app in `frontend/`, built into `priv/static/` and
served at `/`. It talks to the server only over the channels and HTTP API above.

## 10. Not done

- `:question` events (CC `AskUserQuestion`, Codex `requestUserInput`): the
  client renders one, but no backend produces it; a question arrives as plain
  text.
- Turns that survive a Loom restart (a Codex daemon mode).
- Cleanup of uploads removed from the tray, and of the trash.
