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

## Docs

- [docs/architecture.md](docs/architecture.md): how Loom is built
- [docs/backends.md](docs/backends.md): the Claude Code and Codex protocols, as measured
- [docs/deploy.md](docs/deploy.md): EC2 + Cloudflare Tunnel + systemd

## Requirements

- Elixir / Erlang (see `mix.exs`), Node.js + pnpm
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

## API

Everything except `POST /api/login` needs `Authorization: Bearer <token>`
(the socket takes a `token` param).

| Method | Path | |
| --- | --- | --- |
| `POST` | `/api/login` | Password → token |
| `GET` `POST` | `/api/agents` | List / create agent sessions (`backend` is required) |
| `PATCH` `DELETE` | `/api/agents/:id` | Rename / delete |
| `POST` | `/api/agents/:id/files` | Upload an attachment |
| `GET` | `/api/agents/:id/output/*path` | Download a file the agent produced |
| `GET` `POST` | `/api/sessions` | List / create terminals |
| `DELETE` | `/api/sessions/:id` | Stop a terminal |
| `GET` `PUT` | `/api/layout` | Terminal pane layout |

Channels: `agent:<id>`, `terminal:<id>`, and the `agents` lobby (session list).
