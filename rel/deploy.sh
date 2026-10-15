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
mix release --path _build/prod/rel/loom.next --overwrite

if [ "${1:-}" = "--build" ]; then
  echo "built _build/prod/rel/loom.next; not restarting"
  exit 0
fi

_build/prod/rel/loom/bin/loom rpc 'IO.inspect(Loom.Restarter.request())'
