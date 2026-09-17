#!/usr/bin/env bash
# Runs service.luau's filter path against a stubbed host. The entry points are
# chunks the Noctalia host loads rather than modules, so they are concatenated
# into one script instead of being required.
set -euo pipefail
cd "$(dirname "$0")/.."

LUAU=${LUAU:-luau}
if ! command -v "$LUAU" >/dev/null 2>&1; then
  echo "skipped: luau not found (get it from the luau-lang/luau releases)"
  exit 0
fi

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cat tests/filter_sim_prelude.luau tests/fixtures.luau service.luau tests/filter_sim_driver.luau > "$out/sim.luau"
"$LUAU" "$out/sim.luau"
