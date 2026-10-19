#!/bin/sh
# Build a release into _build/prod/rel/loom.next, then ask the running node to
# restart into it once every agent session is idle (Loom.Restarter). systemd
# brings it back up and promote-next.sh swaps loom.next into place on the way.
#
#   rel/deploy.sh             build, then request the restart
#   rel/deploy.sh --build     build only
#
# Safe to run from inside loom: the build never touches the running release,
# and the restart waits for the turn that ran this script to finish.
set -eu
cd "$(dirname "$0")/.."

export MIX_ENV=prod
# Inherited from loom's own .env when run from a loom shell; would make the
# build try to start a server.
unset PHX_SERVER

mix deps.get --only prod
mix assets.deploy

# loom-node: the binaries devices download (into priv/, so the release carries
# them), the CLI agents call here, and the skill that tells them how. A host
# without Go still deploys; it just cannot hand out devices.
if command -v go >/dev/null 2>&1; then
  make -C node -j4
  case "$(uname -m)" in aarch64|arm64) arch=arm64 ;; *) arch=amd64 ;; esac
  mkdir -p "$HOME/.local/bin"
  # Renamed into place, so a CLI call already running keeps its binary.
  cp "priv/node/loom-node-linux-$arch" "$HOME/.local/bin/.loom-node.new"
  mv "$HOME/.local/bin/.loom-node.new" "$HOME/.local/bin/loom-node"
  for skills in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
    mkdir -p "$skills/loom-nodes"
    cp node/SKILL.md "$skills/loom-nodes/SKILL.md"
  done
else
  echo "deploy: no Go toolchain; skipping loom-node (devices cannot be installed from this host)" >&2
fi

# Skills that are not tied to loom-node, for both backends.
for skills in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
  for skill in skills/*/; do
    mkdir -p "$skills/$(basename "$skill")"
    cp "$skill"SKILL.md "$skills/$(basename "$skill")/SKILL.md"
  done
done

mix release --path _build/prod/rel/loom.next --overwrite

if [ "${1:-}" = "--build" ]; then
  echo "built _build/prod/rel/loom.next; not restarting"
  exit 0
fi

_build/prod/rel/loom/bin/loom rpc 'IO.inspect(Loom.Restarter.request())'
