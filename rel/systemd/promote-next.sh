#!/bin/sh
# Swap a staged release into place before loom starts. Keeps exactly one
# previous release (loom.prev) as a manual escape hatch; nothing accumulates.
# The releases are found from where this script lives, rel/systemd/ in the
# checkout.
set -eu
rel="$(cd "$(dirname "$0")/../.." && pwd)/_build/prod/rel"
[ -d "$rel/loom.next" ] || exit 0
rm -rf "$rel/loom.prev"
# The first install has nothing to keep.
[ -d "$rel/loom" ] && mv "$rel/loom" "$rel/loom.prev"
mv "$rel/loom.next" "$rel/loom"
