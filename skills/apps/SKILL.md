---
name: apps
description: Make, change, reorder or remove a Loom app — a program with its own page in Loom's Apps grid (a dashboard, tracker, tool), optionally with a server and a scheduled job. Use when the user asks for an app, a dashboard or page they keep coming back to, something "every N hours" that should just be looked at ("做个 app", "做成 app", "看板", "dashboard", "tracker", "每天自动更新"), or to fix or change an existing app.
---

# apps: Loom's apps

## How an app is served

Loom is only the registry. Caddy is the gateway: it serves every app at
`<apps origin>/apps/<name>/`, and systemd runs the app's processes, so apps stay
up while Loom restarts. An app lives in `~/.loom/apps/<name>/` (`name`:
lowercase letters, digits, `-`; it is also the URL):

```
~/.loom/apps/<name>/
  web/index.html    the page; web/ is served as files
  web/favicon.svg   its favicon, which is also its icon in the grid
  server.ts …       a server, if there is one (any language)
  jobs/…            a job, if data must be fetched on a schedule
  .run/             sockets; Loom's, do not touch
```

`proxy` decides what the server gets:

- `"api"` (default): the server gets `api/*`, and every other path is a file
  from `web/`. `web/index.html` must exist. The page's `fetch("api/todos?x=1")`
  arrives as `GET /api/todos?x=1`.
- `"all"`: every request goes to the server, which then serves the whole site
  itself; `web/` is optional (only its favicon is used, for the grid). The
  server sees the full path, `/apps/<name>/…`, and `X-Forwarded-Prefix:
  /apps/<name>`.

The server listens on the unix socket `$APP_SOCKET`, or on `$PORT` if the app
declares a `port`. systemd starts it on the first request (~0.1 s) and stops
it after `idle` with no connection (default `"10min"`), so anything kept only
in memory is lost. Its working directory is the app's directory, and it is
capped at 256 MB of memory.

The proxy is plain HTTP: every method, header, cookie and body passes through
in both directions, with no time limit; streaming, SSE and WebSocket work.

**Files from disk.** Instead of reading a file and sending it, a server can
answer with only a header, and Caddy sends the file, with `Range` (a phone
plays no video without it):

```ts
res.writeHead(200, { "x-loom-file": "media/12/orig.mov", "content-type": "video/quicktime" })
res.end()
```

- The path is relative to the app's directory, or absolute inside it.
  Anything outside the directory is a 404.
- The path is URL-decoded: encode anything that is not plain ASCII, and `%`,
  `?`, `#`. Node refuses non-ASCII header values outright.
- Headers the server sets (`content-type`, `cache-control`,
  `content-disposition`) are kept; without `content-type`, it comes from the
  file's extension.

Responses get `Cache-Control: no-cache, no-transform` unless the app sets its
own. `/vendor/` on the same origin serves Loom's bundled libraries
(reveal.js, KaTeX).

## Who can reach it

Nobody checks anything at the gateway: anyone who has the URL reaches every
path of every app, the page, the API and the files. Whether an app needs a
login, and what kind, is part of the app. Settle it with the user before
writing code, and build it into the server. That includes programs that push
to the app: the server checks their token.

All apps of one Loom share one origin, so they can read each other's
localStorage and cookies. Set cookies with `Path=/apps/<name>/` and prefix
storage keys with the app's name.

## Calling it

What Loom knows about an app is in `~/.loom/apps.json`. **Never edit that
file**, Caddy's config, or systemd units. Go through `Loom.Apps` over
`bin/loom rpc`, which writes all three and updates the user's grid live.

```sh
B="$(dirname "$LOOM_ENV_FILE")/_build/prod/rel/loom/bin/loom"
$B rpc 'IO.inspect(Loom.Apps.list())'
$B rpc 'IO.inspect(Loom.Apps.put("aws-bill", %{title: "AWS Billing", job: "python jobs/refresh.py", schedule: "*-*-* 00/4:00:00"}))'
$B rpc 'IO.inspect(Loom.Apps.put("todo", %{title: "Todo", server: "node server.ts"}))'
$B rpc 'IO.inspect(Loom.Apps.put("wiki", %{proxy: "all", server: "./bin/wiki", port: 5210}))'
$B rpc 'IO.inspect(Loom.Apps.run("aws-bill"))'      # the job, now, in the background
$B rpc 'IO.inspect(Loom.Apps.move("todo", 1))'       # 1 is first
$B rpc 'IO.inspect(Loom.Apps.delete("todo"))'        # units go, the directory to apps/.trash/
```

- Wrap every call in `IO.inspect`, since rpc prints nothing otherwise.
- For a `"api"` app, write `web/index.html` **before** the first `put`;
  without it the `put` is refused.
- `put` creates or changes. Keys:
  - `title` (default: the name)
  - `proxy` (`"api"` or `"all"`)
  - `server` (a shell command, run in the app's directory)
  - `port` (an integer, 1024–65535, one per app)
  - `idle`
  - `job`
  - `schedule`

  A key left out keeps its value; `nil` clears it. A new app goes last in the
  grid.
- After changing the server's or a job's code, `put` again with the same
  values: that restarts it on the new code.
- Returns `{:ok, app}`, with `url`, or `{:error, reason}`.

## The page

- It lives under `/apps/<name>/`, so use **relative** URLs only:
  `fetch("api/todos")`, `fetch("data.json")`. An absolute `/api/...` is not the
  app's. A Vite build needs `base: "./"`.
- It runs on the apps' own origin, the one in `url` (`LOOM_APPS_URL`; without
  it `http://localhost:5000`, this machine only), never on Loom's. In Loom it
  is shown in an iframe; cookies, storage and PWA install work as on any site.
- **The grid's icon** is the page's favicon: the `<link rel="icon">` (or
  `apple-touch-icon`) in `web/index.html` that points into `web/`. If there is
  none, the grid uses `favicon.svg`/`.png`/`.ico` in `web/`, and if those are
  missing too, the title's first letter. Loom rounds its corners, so draw it
  as a full-bleed square with no rounded corners of its own.
- **Installable**:
  - `web/manifest.webmanifest` with `name`, `short_name`, `"id": "./"`,
    `"start_url": "./"`, `"scope": "./"`, `"display": "standalone"` and
    `icons` (an SVG with `"sizes": "any"`, plus a 512×512 PNG);
  - linked as `<link rel="manifest" href="manifest.webmanifest">`;
  - for iPhone, `<link rel="apple-touch-icon" href="icon-180.png">`, a
    180×180 PNG. iOS ignores the manifest's icons and draws a letter instead.

## The job

- `schedule` is a systemd calendar expression, **in UTC** (Beijing = UTC+8):
  `"hourly"`, `"*-*-* 00/4:00:00"` (every 4 h), `"*-*-* 01:00:00"` (09:00
  Beijing). Check one with `systemd-analyze calendar '<expr>'`. A run missed
  while the host was down happens at boot.
- It runs in the app's directory, with the service's PATH (`~/.venv` Python
  and Node among it).
- Nothing wakes a model by itself. A failure shows only where the app records
  it, and in the journal.
- **Run now**: the server can start the job without waiting for the next tick,
  with `systemctl --user start --no-block app-<name>_job.service`, which is
  what `Loom.Apps.run` does. A start while the job is running is dropped, so a
  job meant to be woken should loop until nothing is left.
- **Handing work to an agent** (only when the app is designed for it):
  - Write `{"title": "…", "prompt": "…"}` to a JSON file and run
    `loom rpc 'IO.inspect(Loom.Agent.new_session_file("/abs/path/req.json"))'`.
    `loom` is on the job's and the server's PATH.
  - It starts a session in the sidebar and returns `{:ok, id}`.
  - Never splice text into rpc code: any `#{…}` in a title someone typed
    runs as Elixir.

## Checking your work

```sh
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
systemctl --user list-units --all 'app-<name>*' --no-legend | cat
journalctl --user -u app-<name>_job -n 20 --no-pager      # a job's output
journalctl --user -u app-<name>_server -n 20 --no-pager   # a server's
journalctl --user -u loom-apps -n 20 --no-pager           # Caddy
curl -s --unix-socket ~/.loom/apps/<name>/.run/http.sock http://x/api/…   # the server directly
curl -s "<url>api/…"                                                        # through Caddy
```

Test the server's logic with its own tests and curl, not through a browser. A
curl of `url` through Caddy shows the page is served. Open it in a browser
only when the user asks, or when something only the page can show is in doubt;
every screenshot read costs tokens. Tell the user it is in the sidebar's
**Apps**.
