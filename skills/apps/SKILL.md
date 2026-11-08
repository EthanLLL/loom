---
name: apps
description: Make, change, reorder or remove a Loom app — a small program with its own page in Loom's Apps grid (a dashboard, tracker, tool), optionally with a server and a scheduled job, that runs without a model. Use when the user asks for an app, a dashboard or page they keep coming back to, something "every N hours" that should just be looked at ("做个 app", "做成 app", "看板", "dashboard", "tracker", "每天自动更新"), or to fix or change an existing app.
---

# apps: programs distilled out of a conversation

An app turns work you would otherwise redo every time into a plain program:
the model builds it once, and from then on it runs with **no model at all** —
a timer fetches the data, a page shows it, a small server saves what the user
types. That is the point: no tokens per use.

**No AI inside an app** unless the user explicitly says this app is about
calling a model. No LLM calls, no Bedrock, no "summarise with Claude" in a job
or server — data in, code, data out. If a step seems to need judgment, ask the
user how they want it decided and write that rule down as code.

## The pieces

An app lives in `~/.loom/apps/<name>/` (`name`: lowercase letters, digits, `-`;
it is also the URL). Every piece but the page is optional:

```
~/.loom/apps/<name>/
  web/index.html    the page (required); web/ is served as it is
  web/favicon.svg   the page's favicon, which is also its icon in the grid
  server.ts         a server, if the page saves or computes anything
  jobs/…            a job, if data must be fetched on a schedule
  data.db, web/data.json …   its data, wherever the app likes
  .run/             sockets; Loom's, do not touch
```

What Loom knows about it — title, order, server and job commands, schedule —
is in `~/.loom/apps.json`. **Never edit that file**, and never write systemd
units yourself: go through `Loom.Apps` over `bin/loom rpc`, which writes the
registry, writes and restarts the units, and updates the user's grid live.

## Calling it

```sh
B="$(dirname "$LOOM_ENV_FILE")/_build/prod/rel/loom/bin/loom"
$B rpc 'IO.inspect(Loom.Apps.list())'
$B rpc 'IO.inspect(Loom.Apps.put("aws-bill", %{title: "AWS Billing", job: "python jobs/refresh.py", schedule: "*-*-* 00/4:00:00"}))'
$B rpc 'IO.inspect(Loom.Apps.put("todo", %{title: "Todo", server: "node server.ts"}))'
$B rpc 'IO.inspect(Loom.Apps.run("aws-bill"))'      # the job, now, in the background
$B rpc 'IO.inspect(Loom.Apps.move("todo", 1))'       # 1 is first
$B rpc 'IO.inspect(Loom.Apps.delete("todo"))'        # units go, the directory to apps/.trash/
$B rpc 'IO.inspect(Loom.Apps.key("token-billing"))'  # {:ok, key} for a program; see below
```

- Wrap every call in `IO.inspect`: rpc prints nothing otherwise.
- Write `web/index.html` **before** the first `put`; it is refused without one.
- `put` creates or changes. Keys: `title` (default: the name), `auth`, `server`,
  `idle` (how long the server may sit unused before it is stopped, default
  `"10min"`), `job`, `schedule`. A key left out keeps its value; `nil` clears
  it. A new app goes last in the grid.
- After changing `server.ts` or a job's script, `put` again with the same
  values: that restarts it on the new code.
- Returns `{:ok, app}` — with `url`, the signed path its page opens under — or
  `{:error, reason}`.

## Who can reach it

Settle this before writing any code — it decides whether the app needs
accounts. Ask the user who will use it, if they have not said:

- **Only the user** — a tool or dashboard for themselves: **private**, the
  default. They open it from their Apps grid (the signed `url`, 30 days; on
  an apps origin it turns into a cookie for the app, renewed on every visit,
  so a bookmark or an installed app keeps working).
- **A few others, for a while**, all the same to the app — a dashboard to
  show family for a month: still **private**; the user sends them the `url`.
  Anyone holding it is the user as far as the app knows, it expires after 30
  days and is re-sent then, and no one person can be shut out.
- **Other people the app must tell apart** — a group, colleagues, customers:
  who said what, who may do what, staying for good: **public**, with accounts
  built in from the start. Loom checks nothing for a public app, so the server
  owns login: a users table in sqlite, passwords hashed (`crypto.scrypt`), a
  random session token returned at login and sent back as
  `Authorization: Bearer`, rate-limited attempts; the page keeps the token in
  localStorage. Designing as private and discovering
  later that people must log in means rewriting the app.

**Public only with the user's explicit yes** — say that anyone on the internet
can reach it, and that its own login is then its only guard. Never on your
own.

Programs are separate from people. For one that pushes to or pulls from a
private app for good — another machine's job, a script — mint a key with
`Loom.Apps.key(name)`: it returns `{:ok, key}` once and keeps only a hash. The
program sends `Authorization: Bearer <key>` to
`<apps origin>/apps/<name>/api/…` (the origin of the `url` from `list`), with
no token in the path.
Calling `key` again replaces it; `Loom.Apps.key(name, nil)` revokes it. Hand
the key over as a file with mode 600 or a secret store, never in `web/`, a
page, or chat output beyond what the user needs.

## The page

- Plain HTML + JS is the default. A React/Vite build works too: build into
  `web/`, with `base: "./"` so asset URLs are relative.
- It runs on the apps' own origin, the one in the `url` from `put`
  (`LOOM_APPS_URL`, e.g. `https://…-apps.…`; without it `http://localhost:5000`,
  this machine only), never on Loom's. Cookies, localStorage and PWA install
  work like on any site. All apps of this Loom share that origin, so prefix
  storage keys with the app's name, and keep nothing there another app must
  not read. What must survive for good goes to the server or the data a job
  writes.
- **Installable**: `web/manifest.webmanifest` with `name`,
  `short_name`, `"id": "./"`, `"start_url": "./"`, `"scope": "./"`,
  `"display": "standalone"` and `icons` (`favicon.svg` with `"sizes": "any"`,
  plus a 512×512 PNG), linked as `<link rel="manifest" href="manifest.webmanifest">`,
  and for iPhone `<link rel="apple-touch-icon" href="icon-180.png">` (a
  180×180 PNG; iOS ignores the manifest's icons and draws a letter instead).
  A browser fetches these without the app's cookie, so Loom serves the
  manifest, the icons it lists and the favicon to anyone; keep them to name
  and looks.
- Use **relative** URLs only — `fetch("api/todos")`, `fetch("data.json")`. The
  page lives under `/apps/<name>/`; an absolute `/api/...` is not the app's.
- CDNs are allowed; for charts read the `dataviz` skill first.
- **One icon for both**: give the page a favicon, `web/favicon.svg`, linked as
  `<link rel="icon" href="favicon.svg">` (relative). The grid shows whatever
  that link points at (else `favicon.svg`/`.png`/`.ico` in `web/`, else the
  title's first letter). Draw it as a full-bleed square — a colour or gradient
  edge to edge with a simple white glyph — and no rounded corners of its own:
  Loom rounds it, and the tab shows it small, so keep the glyph bold.
- Show the data's age ("更新于 …") and, when the last refresh failed, the error.

## The server

Only if the page saves or computes. Node 24 + TypeScript, run directly — no
build, no `package.json`, no `node_modules`:

```ts
import http from "node:http"
import { DatabaseSync } from "node:sqlite"   // built in; synchronous, which is fine here
const db = new DatabaseSync("data.db")        // cwd is the app's directory
http.createServer(handler).listen(process.env.APP_SOCKET)
```

- Listen on `process.env.APP_SOCKET` (a unix socket), never a port.
- It receives exactly what the page sent under `api/`: the page's
  `fetch("api/todos?x=1")` arrives as `GET /api/todos?x=1`. Only `api/*`
  reaches it; everything else is a file from `web/`.
- Forwarded: method, query, body, `content-type`, `accept`, for a public app
  `authorization`, and on an apps origin the app's own cookies (`set-cookie`
  them with `Path=/apps/<name>/`). A private app gets no auth at all — Loom has
  checked the link, cookie or key already. Back: status, headers, body.
- HTTP/1.0, one request per connection, buffered, 30 s at most: plain JSON
  request/response only — **no SSE, no WebSocket, no streaming**.
- **Files are not read and returned.** For a photo, a video, a download —
  anything not small — check what you must, then answer with only a header:
  `res.writeHead(200, {"x-loom-file": "media/12/orig.mov"}); res.end()`. The
  path is relative to the app's directory and must stay inside it. Loom sends
  the file from disk, with `Range` (a phone plays no video without it) and the
  content type from the extension unless you set one; other headers you set,
  such as `content-disposition`, go along.
- It is started on the first request (~0.1 s) and stopped after `idle`, so keep
  no state in memory that sqlite does not also have. 256 MB memory cap.

## The job

For data that must be fetched — an API, AWS, a site. Python (`~/.venv`, with
pandas, boto3, requests…) is the default; anything on the PATH works.

- `schedule` is a systemd calendar expression, **in UTC** (Beijing = UTC+8):
  `"hourly"`, `"*-*-* 00/4:00:00"` (every 4 h), `"*-*-* 01:00:00"` (09:00
  Beijing). Check one with `systemd-analyze calendar '<expr>'`. A run missed
  while the host was down happens at boot.
- It runs in the app's directory. Write data atomically (a temp file, then
  rename) so the page never reads half a file.
- **On failure keep the last good data**, record the error and its time next to
  it (e.g. `"error"`, `"error_at"` in `data.json`), and exit non-zero. The page
  shows that error; the user then asks an agent to look. Nothing wakes a model
  by itself.
- **Run now, not at the next tick**: the server can start the job when the page
  hands it work, `systemctl --user start --no-block app-<name>-job.service`
  (as `Loom.Apps.run` does). A start while the job is running is dropped, so
  such a job loops until nothing is left.
- **Handing work to an agent** — only when the user designed the app to (a
  finished batch to be filed by a Loom session, say): write
  `{"title": "…", "prompt": "…"}` to a JSON file and run
  `loom rpc 'IO.inspect(Loom.Agent.new_session_file("/abs/path/req.json"))'`
  (`loom` is on the job's and server's PATH). It starts a session in the
  sidebar and returns `{:ok, id}`. Never splice text into rpc code: any
  `#{…}` in a title someone typed runs as Elixir.

## Checking your work

Before telling the user it is done:

```sh
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
systemctl --user list-units --all 'app-<name>*' --no-legend | cat
journalctl --user -u app-<name>-job -n 20 --no-pager      # a job's output
journalctl --user -u app-<name>-server -n 20 --no-pager   # a server's
curl -s --unix-socket ~/.loom/apps/<name>/.run/http.sock http://x/api/…   # the server, as Loom calls it
```

Then open the page itself with Playwright at `url` (from `put`/`list`), light
and dark, and look at a screenshot.

Tell the user it is in the sidebar's **Apps**. Do not hand out the URL unless
asked: it is a credential (30 days, this app only), and Loom opens apps itself.
