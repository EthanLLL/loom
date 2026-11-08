# Loom

A single-user, self-hosted front end for coding agents. Chat with Claude Code
or Codex sessions running on your server, with shells beside them, from any
browser or phone. Sessions live on the server: close the tab, come back on
another device, and the turn has kept running.

- **Backend**: Elixir / Phoenix. One GenServer per session and per PTY,
  streamed over Phoenix Channels. State is on disk under `~/.loom`.
- **Frontend**: Vite + React + xterm.js, in `frontend/`.
- **Agents**: the `claude` and `codex` CLIs do the work. Loom makes no model
  requests of its own.

## What it does

**Sessions**
- Claude Code or Codex, chosen per session and fixed for its life.
- Every device sees the same session; a reconnecting tab replays only what it
  missed. A message sent mid-turn joins the running turn.
- Attachments (images scaled to 2000 px in the browser, EXIF kept). The
  composer keeps a draft per session.
- `/compact`, `/reload` (new CC / Codex config, no restart), `/cron`.
- Directories, one level deep, in the sidebar; search over titles and over
  what was said (ripgrep). A deleted session goes to a trash on disk.

**Canvas.** Whatever an agent writes to the session's `output/` opens beside
the chat: pages, charts, images, video, PDF, Markdown, tables. A file tree
lists every upload and output of the session. Pages run sandboxed on an opaque
origin. Slides are reveal.js decks served by Loom itself, with a PDF button.

**Terminals.** Real PTYs beside the chat. They outlive the tab, can be shared
by two devices, and pass OSC 52 clipboard writes to the browser.

**Apps.** Repeated work an agent distills into a plain program, so using it
needs no model: a page, optionally a server and a scheduled job. systemd runs
them (socket-activated, idle exit, timers); they are served on an origin of
their own and open from an Apps grid in the sidebar. Private by default, with
keys for programs that push to them.

**Scheduled prompts.** Cron jobs that submit a prompt to a session; agents
make them, `/cron` lists them.

**Your devices (loom-node).** A small Go daemon on a Mac, Linux box or WSL
dials out to Loom, so agents can run commands and read and write files there.
One-line install from the Devices dialog; a token per device, kept as a hash.

**Browser.** An optional Chromium on a virtual display that agents drive over
CDP, logged in where you signed in once. You take it over from the sidebar
(noVNC) for logins and captchas.

**App shell.** Installable PWA; Web Push when a turn ends (no account, Loom
signs them); light and dark themes; built for phones; optional Vim-style keys
([docs/keys.md](docs/keys.md)). `rel/deploy.sh` deploys Loom from inside Loom
and restarts once every session is idle.

Agent instructions ship as skills in `skills/` (apps, browser, cron, sessions,
slides) and `node/SKILL.md`, copied to both backends on deploy.

## Docs

- [docs/architecture.md](docs/architecture.md): how Loom is built
- [docs/backends.md](docs/backends.md): the Claude Code and Codex protocols, as measured
- [docs/deploy.md](docs/deploy.md): EC2 + Cloudflare Tunnel + systemd
- [docs/keys.md](docs/keys.md): the keyboard

## Requirements

- Elixir / Erlang (see `mix.exs`), Node.js + pnpm, Go (for `loom-node`)
- `claude` and `codex` on `PATH`, both logged in
- Optional: `rg` for search, systemd user units for apps

## Development

```sh
mix setup && (cd frontend && pnpm install)

mix phx.server             # backend on :4000
cd frontend && pnpm dev    # frontend on :5173, proxies /api and /socket
```

Open http://localhost:5173. The password is `LOOM_PASSWORD` (`loom` in dev).

| Command | |
| --- | --- |
| `mix test` | Backend tests |
| `mix precommit` | Compile with warnings as errors, format, test |
| `cd frontend && pnpm build` | Type-check and build |
| `cd frontend && pnpm md:check` | Markdown renderer cases |
| `cd frontend && pnpm transcript …` | Record / replay a live agent stream ([details](docs/architecture.md#91-debugging-record-and-replay)) |

## License

[MIT](LICENSE)
