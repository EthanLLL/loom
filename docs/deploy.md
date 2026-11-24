# Deploy

Loom runs on one Linux machine with systemd, as one ordinary user. The BEAM
serves plain HTTP on `127.0.0.1:4000`; TLS, and whatever puts Loom on the
network, are yours to choose and run in front of it. There is no release
package: you build from this repository on the server.

Ubuntu and Debian are the reference below, on x86_64 (`amd64`) or arm64
(`aarch64`). Where a step differs by architecture or distribution, it says so.

## 1. What Loom needs

Required:

- Linux with systemd, and a user to run Loom as. Agents and terminals run as
  that user, with no sandbox.
- Erlang/OTP and Elixir `~> 1.17` (`mix.exs`), to build and run.
- Node.js and pnpm, to build the frontend. Not needed at run time, except by
  agents that use them.
- At least one agent CLI, installed and logged in: `claude` (Claude Code),
  `codex` (Codex) or `kiro-cli` (Kiro). Each is optional; install the ones
  you will use.

Optional:

- Go 1.27.2 or newer (`node/go.mod`): builds the `loom-node` binaries that
  devices download. Without it Loom still deploys, but cannot hand out
  devices.
- Caddy 2.7+: serves the apps. Without it apps are registered but not served.
- `rg` (ripgrep): search over what was said. Without it search finds sessions
  by title only, and says so.
- The browser stack (Xvfb, x11vnc, a Chromium): the agents' shared browser.

## 2. Toolchain

Base packages:

```sh
sudo apt-get update
sudo apt-get install -y git curl build-essential cmake ripgrep
```

`build-essential` and `cmake` build the PTY library's NIF (`expty`) when no
precompiled one matches the machine, and always under `mix test`.

### Erlang/OTP and Elixir

The official installer fetches prebuilt OTP and Elixir into
`~/.elixir-install/installs/`, on x86_64 and arm64 alike. Loom is built with
Elixir 1.20.4 on OTP 28.4:

```sh
curl -fsSO https://elixir-lang.org/install.sh
sh install.sh elixir@1.20.4 otp@28.4
export PATH=$HOME/.elixir-install/installs/otp/28.4/bin:$HOME/.elixir-install/installs/elixir/1.20.4-otp-28/bin:$PATH
elixir --version
```

Its prebuilt OTP targets glibc distributions such as Ubuntu and Debian. On
others (Alpine, older RHEL) use the distribution's packages if they are new
enough, or a version manager such as `asdf` or `mise`.

### Node.js and pnpm

Loom's frontend is built with Node 24. Any install works; for example nvm,
which puts it under `~/.nvm/versions/node/v24.x.y/bin`:

```sh
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
. ~/.nvm/nvm.sh
nvm install 24
npm install -g pnpm
```

### Go (optional)

Download the tarball for the machine's architecture from https://go.dev/dl/:

```sh
case "$(uname -m)" in aarch64|arm64) a=arm64 ;; *) a=amd64 ;; esac
curl -fsSLO https://go.dev/dl/go1.27.2.linux-$a.tar.gz
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go1.27.2.linux-$a.tar.gz
export PATH=/usr/local/go/bin:$PATH
```

The binaries are pure Go, cross-compiled for every device type
(`darwin-arm64`, `darwin-amd64`, `linux-arm64`, `linux-amd64`), so the
server's own architecture does not matter.

## 3. Agent CLIs and their credentials

Loom makes no model requests itself, and holds no model keys. Each CLI brings
its own model choice and credentials. Install the ones you want, on the
service's `PATH`, and log in as the user Loom runs as:

- **Claude Code** (`claude`): log in with `claude`, or set
  `CLAUDE_CODE_USE_BEDROCK=1` and provide AWS credentials. `CLAUDE_CONFIG_DIR`
  is honoured; unset, `~/.claude`.
- **Codex** (`codex`): `codex login`, or a provider in
  `~/.codex/config.toml`. `CODEX_HOME` is honoured; unset, `~/.codex`. Loom
  starts one shared `codex app-server` at boot.
- **Kiro** (`kiro-cli`): `kiro-cli login`; check with `kiro-cli whoami`. On a
  machine without a browser: `kiro-cli login --identity-provider <start URL>
  --region <region> --use-device-flow`, without `--license`. Or an API key:
  kiro-cli reads it only from `KIRO_API_KEY`, so give it to the service as
  machine config, never in Loom's `.env`. A systemd drop-in does it:

  ```sh
  sudo systemctl edit loom
  # [Service]
  # EnvironmentFile=/home/<user>/.config/kiro/kiro.env
  ```

  with `KIRO_API_KEY=…` in that file, mode 0600. An API key in the
  environment wins over a login.

Claude Code sessions can also use profiles: another provider or key per
session, as Claude Code settings files in `~/.loom/profiles/<name>.json` (see
the `profiles` skill).

## 4. Configuration

Loom reads its environment from a `.env` file, sourced by `rel/env.sh.eex` on
every start: `$LOOM_ENV_FILE` if set, else `.env` next to the release, else
`./.env`. Plain `KEY=value` lines; no `export`. Start from
[.env.example](../.env.example):

```sh
cp .env.example .env && chmod 600 .env
```

Required:

| Variable | Meaning |
| --- | --- |
| `SECRET_KEY_BASE` | Signs login tokens. Generate with `mix phx.gen.secret`. Changing it signs every device out. |
| `LOOM_PASSWORD` | The password. |
| `PHX_SERVER=true` | Without it the release serves no HTTP. |

Optional:

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `4000` | Loom's HTTP port. |
| `LOOM_BIND` | `127.0.0.1` | Listen address, for Loom and for the apps (Caddy). An IP address; a hostname is refused. Widen it only if what fronts Loom runs on another machine, and then restrict ingress to that host. |
| `PHX_HOST` | `localhost` | The public hostname. Recorded only; nothing checks it. |
| `LOOM_HOME` | `~/.loom` | Loom's state (§12). Outside the release, which a deploy replaces. |
| `LOOM_WORKSPACE` | the user's home | Working directory of new sessions. |
| `LOOM_IDLE_RELEASE_MINUTES` | `5` | How long a session keeps its Claude Code or Kiro process after its last turn. A whole number above 0. |
| `LOOM_CLAUDE_CLI` | `claude` | The Claude Code binary: a name on `PATH`, an absolute path or a wrapper. |
| `LOOM_CODEX_CLI` | `codex` | The same, for Codex. |
| `LOOM_KIRO_CLI` | `kiro-cli` | The same, for Kiro. |
| `LOOM_KIRO_MODEL` | Kiro's `auto` | The model a new Kiro session starts on, an id from `kiro-cli chat --list-models`. |
| `LOOM_APPS_PORT` | `5000` | The port Caddy serves the apps on, at `LOOM_BIND`. |
| `LOOM_APPS_URL` | `http://localhost:<LOOM_APPS_PORT>` | The apps' public origin, e.g. `https://apps.example.com` (§7). Unset, apps work on this machine only. |

No TLS settings and no model keys are needed. Loom also passes its own
environment on to agents and terminals, so set `HOME`, `SHELL`, `LANG` and
`PATH` in the service (§6), not here.

## 5. Build

The repository is the build directory; clone it where the service will run
from, as the service user:

```sh
git clone https://github.com/EthanLLL/loom.git ~/loom
cd ~/loom
rel/deploy.sh --build
```

`rel/deploy.sh --build` does, with `MIX_ENV=prod`:

1. `mix deps.get --only prod`.
2. `mix assets.deploy`: `pnpm install --frozen-lockfile` and `pnpm build` in
   `frontend/` (type-check, Vite build, then `tools/vendor.mjs`, which copies
   reveal.js and KaTeX into `dist/vendor/`), then replaces `priv/static` with
   `frontend/dist`.
3. If `go` is on `PATH`: `make -C node`, which builds the four `loom-node`
   binaries into `priv/node/`; installs the one for this machine as
   `~/.local/bin/loom-node`, the CLI agents call; and copies `node/SKILL.md`
   as the `loom-nodes` skill.
4. Copies every `skills/*/SKILL.md` into `~/.claude/skills`, `~/.codex/skills`
   and `~/.kiro/skills`. These paths are fixed; they do not follow
   `CLAUDE_CONFIG_DIR` or `CODEX_HOME`.
5. `mix release --path _build/prod/rel/loom.next --overwrite`.

Without `--build`, it then asks the running Loom to restart (§12).

The manual equivalent:

```sh
export MIX_ENV=prod
mix deps.get --only prod
mix assets.deploy
make -C node -j4                    # optional, needs Go
mix release --path _build/prod/rel/loom.next --overwrite
```

plus the copies of steps 3 and 4. A release built without `mix assets.deploy`
answers `/` with a 404 saying so.

On the first install there is no `_build/prod/rel/loom` yet; the promote
step (§6) moves `loom.next` into place when the service first starts.

`~/.local/bin` must be on the service's `PATH` for agents to find
`loom-node`.

## 6. systemd

[`rel/systemd/loom.service`](../rel/systemd/loom.service) is a template
written for one machine. Copy it and adjust:

- `User=`, and `Environment=HOME=` to that user's home.
- `WorkingDirectory=`, `LOOM_ENV_FILE`, `ExecStartPre=` and `ExecStart=` to
  where the repository is.
- `Environment=SHELL=` to the shell terminals should open; unset, Loom falls
  back to `/bin/zsh`.
- `Environment=PATH=`: systemd's default `PATH` has none of the toolchain.
  It is inherited by every agent and terminal, so give it the user's whole
  toolchain: `~/.local/bin`, the OTP and Elixir `bin` directories, Node's
  `bin` (by version, under nvm), Go, and wherever the agent CLIs are.

[`rel/systemd/promote-next.sh`](../rel/systemd/promote-next.sh) hard-codes
the release directory too; set `rel=` to `<repository>/_build/prod/rel`.

```sh
sudo cp rel/systemd/loom.service /etc/systemd/system/   # the edited copy
sudo systemctl daemon-reload
sudo systemctl enable --now loom
journalctl -u loom -f
```

Apps run as systemd user units of the same user, and its user manager runs
only while the user is logged in unless lingering is on:

```sh
sudo loginctl enable-linger <user>
```

What the unit does:

- `ExecStartPre` runs `promote-next.sh`. If `_build/prod/rel/loom.next`
  exists, it moves the current release to `loom.prev` (replacing any older
  one) and `loom.next` into its place. Otherwise it does nothing.
- `Restart=always`, 3 s apart. `StartLimitIntervalSec=60` with
  `StartLimitBurst=5`: five failed starts within 60 s and systemd leaves it
  down. There is no automatic rollback. To go back:

  ```sh
  sudo systemctl stop loom
  cd <repository>/_build/prod/rel
  mv loom loom.bad && mv loom.prev loom
  sudo systemctl reset-failed loom && sudo systemctl start loom
  ```

- `KillMode=control-group`: stopping Loom stops every agent and terminal it
  started.
- `OOMPolicy=continue`: the kernel's OOM killer takes one process, usually a
  runaway agent tool, and not the service.

Once it is up, sign in and, in Settings → Sign-in, add a passkey or an
authenticator. Until an authenticator exists, the password alone gets in.

## 7. In front of Loom

TLS and the way in are the deployer's: a reverse proxy on the same machine, or
a tunnel. Whatever it is must:

- terminate TLS. Passkeys and Web Push work only on an `https` origin (or
  `http://localhost`). A passkey belongs to the hostname it was made on, so
  keep the hostname stable.
- pass WebSockets on `/socket` (the app), `/node/websocket` (devices),
  `/browser/vnc` (the browser) and `/devices/<id>/port/<port>` (Connect's
  relay). Everything else is plain HTTP.
- pass the public `Host` header and set `X-Forwarded-Proto: https`. The
  device install script (§10) tells a device to dial the origin it was
  fetched from, built from those two.
- allow request bodies up to 120 MB (attachments).
- not buffer responses for long, nor time out idle WebSockets quickly. Loom
  and its clients send heartbeats.

Loom does not check `Host` or `Origin` for access, and does not redirect to
`https`: the last hop is plain HTTP over loopback. Every API route and socket checks
the login token itself.

The apps need an origin of their own, never Loom's: a second hostname, pointed
at `LOOM_BIND:LOOM_APPS_PORT` (Caddy), set as `LOOM_APPS_URL`. Apps have no
access control of their own unless they add it, so put that hostname behind
whatever access control suits you.

## 8. Apps

Install Caddy 2.7 or newer on the service's `PATH`. Use the release binary,
not the distribution's package, whose system service listens on `:80`:

```sh
case "$(uname -m)" in aarch64|arm64) a=arm64 ;; *) a=amd64 ;; esac
v=2.11.9
curl -fsSLO https://github.com/caddyserver/caddy/releases/download/v$v/caddy_${v}_linux_$a.tar.gz
tar xzf caddy_${v}_linux_$a.tar.gz caddy && sudo install -m 755 caddy /usr/local/bin/
```

Loom writes the rest itself, at boot and on every change:

- `~/.loom/caddy.json`, Caddy's whole config, loaded over the admin socket
  `~/.loom/caddy-admin.sock`.
- `~/.config/systemd/user/loom-apps.service`, which runs Caddy from that file,
  enabled and started. The apps stay up while Loom restarts.
- Per app, `app-<name>.socket` / `.service` and `app-<name>_job.timer` /
  `.service` in the same directory. Servers are socket-activated and exit when
  idle, through `/usr/lib/systemd/systemd-socket-proxyd`.

If `caddy` is not on `PATH` at boot, Loom logs a warning and serves no apps.

## 9. The browser (optional)

A Chromium on a virtual display, for agents over CDP and for you to take over
from the sidebar. systemd holds its two ports and starts it on the first
connection; after 10 minutes with neither used, it stops. Its profile, and so
its logins, persist in `~/.local/share/loom-browser/profile`.

| Port (loopback) | What |
| --- | --- |
| `9222` | CDP for agents, held by `loom-browser-cdp.socket` |
| `9223` | Chromium's own CDP port |
| `5900` | VNC for Loom's browser view (`/browser/vnc`), held by `loom-browser-vnc.socket` |
| `5901` | x11vnc's own port |

Display `:99`, 1280x800. `loom-browser.sh` reads `LOOM_BROWSER_DISPLAY`,
`LOOM_BROWSER_SIZE`, `LOOM_BROWSER_PROFILE`, `LOOM_BROWSER_CDP_PORT` and
`LOOM_BROWSER_VNC_PORT` to change them; the sockets and proxies in the units
must then change too.

Packages:

```sh
sudo apt-get install -y xvfb x11vnc x11-utils
```

A browser. `loom-browser.sh` uses Google Chrome if `google-chrome-stable` is
on `PATH`, otherwise the newest Playwright Chromium under
`~/.cache/ms-playwright`:

- x86_64: Google Chrome.

  ```sh
  curl -fsSLO https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  sudo apt-get install -y ./google-chrome-stable_current_amd64.deb
  ```

- arm64: Playwright's Chromium, as the service user:

  ```sh
  npx playwright install --with-deps chromium
  ```

  `--with-deps` installs its system libraries with apt; on other
  distributions install them yourself.

  On Ubuntu 23.10 and later, AppArmor denies Playwright's Chromium the user
  namespaces its sandbox needs. Install the profile, with its path changed
  from `/home/ubuntu` to the service user's home:

  ```sh
  sudo cp rel/browser/loom-chromium.apparmor /etc/apparmor.d/loom-chromium
  sudo apparmor_parser -r /etc/apparmor.d/loom-chromium
  ```

  Debian and other distributions without that restriction need no profile.

The units in `rel/browser/` hard-code `User=ubuntu`, `HOME=/home/ubuntu` and
`/home/ubuntu/loom/rel/browser/loom-browser.sh`. Change them to the service
user, its home and the repository, then:

```sh
sudo cp rel/browser/loom-browser*.service rel/browser/loom-browser*.socket /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now loom-browser-cdp.socket loom-browser-vnc.socket
```

To stop the browser, stop the proxies (`loom-browser-cdp.service`,
`loom-browser-vnc.service`), not restart them: a proxy started with no
connection never goes idle.

## 10. Devices

A device is a Mac, Linux machine or WSL running `loom-node`, which dials out
to Loom; nothing listens on the device. The server needs the binaries from
§5 (Go).

In Loom, open Devices (foot of the sidebar), add one, and run the line it
shows on the device:

```sh
curl -fsSL https://<loom host>/node/install/<code> | sh
```

The code works once. The script downloads the binary for that system and
installs it as a per-user service: launchd (`~/Library/LaunchAgents`) on
macOS, a systemd user unit `loom-node.service` on Linux, with lingering
turned on so it runs without a login. WSL needs `systemd=true` under `[boot]`
in `/etc/wsl.conf`; without systemd it is started in the background and does
not survive a restart. Installing against a second Loom adds it; one device can serve
several.

Connect, for macOS devices, shows the Mac's screen. It needs on the Mac either
[loom-mac-screen](https://github.com/EthanLLL/loom-mac-screen) (H.264, on
`127.0.0.1:5960`) or Screen Sharing turned on (System Settings → General →
Sharing), which Loom uses over VNC on 5900 when the first is not running. The
browser reaches the Mac directly over WebRTC when the networks allow it, using
public STUN servers and no TURN; otherwise Loom relays it over
`/devices/<id>/port/<port>`.

## 11. Push notifications

Web Push needs no account and no settings. On first boot Loom makes a VAPID
key pair and keeps it in `~/.loom/push.json`, with one subscription per device
that turned notifications on (Settings → General). Every subscription is bound
to that key pair: if the file is lost or the keys change, every device has to
turn notifications on again. The site must be on `https` (§7). Safari on iOS
offers Web Push only to a site added to the Home Screen.

## 12. Updating and backups

To update:

```sh
cd <repository> && git pull && rel/deploy.sh
```

It builds into `loom.next` (§5), leaving the running release alone, then calls
`Loom.Restarter.request()` on the running node. Once every session is idle,
including one whose agent ran the script, Loom stops; systemd starts it again
and `promote-next.sh` swaps the new release in, keeping the old one as
`loom.prev`. A request that has not fired after 10 minutes is dropped, and
Loom stays up on the old release. So an agent inside Loom can deploy Loom: it
cannot restart the service directly, as it is part of it.

`rel/deploy.sh --build` builds without asking for the restart.

Back up `~/.loom` (or `LOOM_HOME`) and `.env`. In `~/.loom`:

| Path | What |
| --- | --- |
| `sessions/` | Every session: header, transcript, attachments, `output/`; deleted ones in `sessions/.trash/` |
| `auth.json` | Passkeys, the authenticator's secret, hashed recovery codes, logins |
| `push.json` | The VAPID key pair and push subscriptions |
| `nodes.json` | Devices, with hashed tokens |
| `node-cli.json` | The key the local `loom-node` CLI signs in with |
| `apps.json` | The apps registry |
| `apps/` | Each app's code and data |
| `app-icons/` | The registry's copies of app icons |
| `caddy.json` | Caddy's config, rewritten at boot |
| `cron.json` | Scheduled prompts |
| `directories.json` | Sidebar groups and their order |
| `profiles/` | Claude Code profiles, which may hold API keys |

The agent CLIs keep their own state and credentials in `~/.claude`,
`~/.codex` and `~/.kiro`; back those up as well if sessions should resume
after a restore. The browser's logins are in
`~/.local/share/loom-browser/profile`.
