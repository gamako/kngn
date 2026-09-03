#!/usr/bin/env bash
# Replay the dropdown's pointer, keyboard and placement contract, then leave snapshots for
# visual inspection. Run from the repository root inside the development shell.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/layer-dropdown-e2e.XXXXXX")
REPLAY_OUT="$WORK/replay"
mkdir -p "$REPLAY_OUT"

command -v zig >/dev/null 2>&1 || {
    echo "[layer-dropdown] zig not on PATH; run this inside the dev shell" >&2
    exit 1
}

echo "[layer-dropdown] replay output: $REPLAY_OUT"
cd "$ROOT"
KNGN_HEADLESS=1 \
KNGN_HARNESS_MANUAL_CLOCK=1 \
KNGN_HARNESS_SCRIPT="$SCRIPT_DIR/e2e.txt" \
KNGN_HARNESS_OUT="$REPLAY_OUT" \
zig build run-example_48

echo "[layer-dropdown] replay snapshots:"
find "$REPLAY_OUT" -type f -name '*.png' -print | sort
shots=$(find "$REPLAY_OUT" -type f -name '*.png' | wc -l | tr -d ' ')
if [[ "$shots" -lt 4 ]]; then
    echo "[layer-dropdown] expected at least 4 snapshots, got $shots" >&2
    exit 1
fi
