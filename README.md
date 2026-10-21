# Loom

A single-user, self-hosted front end for coding agents. Chat with Claude Code
or Codex sessions running on your server, and open real shells next to them,
from any browser or phone. Sessions live on the server: close the tab, come
back later on another device, and the turn has kept running.

- **Backend**: Elixir / Phoenix. One GenServer per agent session, one per PTY,
  streamed over Phoenix Channels. State is on disk under `~/.loom`.
- **Frontend**: Vite + React + xterm.js, in `frontend/`.
- **Agents**: the `claude` and `codex` CLIs do the actual work. Loom makes no
  model requests of its own.

## What it does

### Agent sessions

- **Claude Code and Codex**, chosen per session. Claude Code keeps one warm
  `claude -p` per session, so replies start in about 2s instead of 10s.
- **Every device sees the same session.** Start a turn on the laptop, watch it
  finish on the phone. A reconnecting tab replays only what it missed.
- **Talk while it works.** A message sent mid-turn joins the running turn
  instead of waiting for it to end.
- **Attachments**: drop in images and files; they open in the canvas before
  and after sending.
- **Slash commands**: `/compact`, `/reload` (pick up new Claude Code / Codex
  config without restarting Loom), `/cron`, with a menu in the composer.
- Sessions survive Loom restarts and are restored from disk.

### Terminals

- Real PTY shells beside the chat, several at once.
- They outlive the tab: reconnect and the screen is redrawn. Two devices can
  share one shell.
- OSC 52 clipboard writes (tmux, nvim) reach the browser's clipboard.

### Canvas

- Anything an agent writes to the session's `output/` directory shows up in a
  browser pane beside the chat. Agents use it for pages, charts, dashboards
  and image galleries.
- Built-in viewers for images, audio and video, Markdown, CSV/tables and text;
  folders download as zip.
- A file tree beside the canvas, like NERDTree, lists everything in the
  session, what you uploaded and what the agent made, so last week's files are
  easy to find.
- Pages run sandboxed on an opaque origin, so they cannot reach Loom's
  token or API.
- Canvas and terminals can take the whole window, for presenting.

### Slides

- Ask for a deck and the agent writes a reveal.js page into the canvas, with
  code highlighting and KaTeX math.
- reveal.js and KaTeX are served by Loom itself, so a deck opens whenever Loom
  does, even offline.
- A PDF button in each deck prints it from your own browser.

### Scheduled prompts

- "Every weekday at 10:00, check …": cron jobs that submit a prompt to a
  session at the set time. Agents create them for you; `/cron` lists them.

### Your own devices (loom-node)

The server is not your computer, but your computers can join it. Install
`loom-node` on a Mac, a Linux box or WSL, and agents in any session can work on
that machine as you:

- **Run commands** in your login shell, with output streamed back and the real
  exit code.
- **Read and write files**, binary-safe, so an agent can fetch a document from
  your laptop, work on it on the server, and put the result back.
- **One-line install.** Add a device in the Devices dialog (foot of the
  sidebar), then paste the `curl … | sh` command it gives you into that
  machine's terminal. It installs a per-user service (launchd on macOS,
  systemd on Linux) that reconnects by itself after sleep and reboot.
- **Outbound only.** The device dials Loom; nothing on it listens on a port,
  so it works behind NAT and home routers.
- **Safe defaults.** Each device has its own token, stored only as a hash;
  removing the device revokes it. Commands are time-limited, and everything a
  device runs is logged on that device.
- The sidebar shows which devices are online, live.

### App

- Installable as a PWA, with the title bar hidden on desktop.
- **Notifications** when a turn ends, on the phone's lock screen too (iPhone:
  from the home-screen app). Not for the session you are looking at; tapping
  one opens the session. No account or API key: Loom signs them itself.
- Built for phones too: the keyboard, safe areas and scrolling behave.
- **Vim-style keys** on desktop: `i` to type, `j`/`k` to scroll, Space as the
  leader for the panes, `?` for the list. See [docs/keys.md](docs/keys.md).
- Deploy Loom from inside Loom: `rel/deploy.sh` stages a new release, and Loom
  restarts into it once every session is idle, so no turn is cut off.

## Docs

- [docs/architecture.md](docs/architecture.md): how Loom is built
- [docs/backends.md](docs/backends.md): the Claude Code and Codex protocols, as measured
- [docs/deploy.md](docs/deploy.md): EC2 + Cloudflare Tunnel + systemd
- [docs/keys.md](docs/keys.md): the keyboard

## Requirements

- Elixir / Erlang (see `mix.exs`), Node.js + pnpm, Go (for `loom-node`)
- `claude` and `codex` on `PATH`, both logged in

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
| `cd frontend && pnpm transcript …` | Record / replay a live agent stream ([details](docs/architecture.md#81-debugging-record-and-replay)) |

## License

[MIT](LICENSE)
