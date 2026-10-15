#!/bin/sh
# Swap a staged release into place before loom starts. Keeps exactly one
# previous release (loom.prev) as a manual escape hatch; nothing accumulates.
set -eu
rel=/home/ubuntu/loom/_build/prod/rel
[ -d "$rel/loom.next" ] || exit 0
rm -rf "$rel/loom.prev"
mv "$rel/loom" "$rel/loom.prev"
mv "$rel/loom.next" "$rel/loom"
