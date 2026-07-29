# Loom

A web-based terminal: run your server's shell, Neovim, and TUIs (like Claude
Code) directly in the browser. Supports multiple tabs, side-by-side split
panes (up to 3), and persistent sessions — close the browser and reconnect, and
your tabs, panes, and running programs are still there.

- **Backend** — Elixir / Phoenix. Each terminal session is a supervised
  GenServer holding a real PTY (via [`expty`](https://hex.pm/packages/expty)),
  streamed to the browser over a Phoenix Channel.
- **Frontend** — Vite + React + [xterm.js](https://xtermjs.org/), a separate
  app in `frontend/`.

The two run as separate processes in development.

## Requirements

- Elixir / Erlang (see `mix.exs` for versions)
- Node.js + [pnpm](https://pnpm.io/)
- A shell to spawn (defaults to `$SHELL`, falls back to `/bin/zsh`)

## Setup

```bash
# Backend deps
mix setup

# Frontend deps
cd frontend && pnpm install && cd ..
```

## Development

Run both in separate terminals:

```bash
# Terminal 1 — backend (Phoenix on :4000)
mix phx.server

# Terminal 2 — frontend (Vite dev server on :5173)
cd frontend && pnpm dev
```

Then open **http://localhost:5173**. Vite proxies `/api` and `/socket` to the
backend, so everything is same-origin.

### Password

Login is gated by a single password read from `LOOM_PASSWORD` (defaults to
`loom` in dev). The token is kept in `sessionStorage`, so every new browser
session requires re-entering it.

```bash
LOOM_PASSWORD=your-secret mix phx.server
```

## Commands

| Command | What it does |
| --- | --- |
| `mix phx.server` | Start the backend |
| `mix test` | Run the backend test suite |
| `mix precommit` | Compile (warnings as errors), check deps, format, test |
| `cd frontend && pnpm dev` | Start the frontend dev server |
| `cd frontend && pnpm build` | Type-check and build the frontend for production |

## API

All routes except `POST /api/login` require an `Authorization: Bearer <token>`
header (or a `token` param for the socket).

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/api/login` | Exchange password for a token |
| `GET` | `/api/sessions` | List live sessions |
| `POST` | `/api/sessions` | Create a session |
| `DELETE` | `/api/sessions/:id` | Stop a session |
| `GET` | `/api/layout` | Get the saved tab/pane layout |
| `PUT` | `/api/layout` | Save the layout |
