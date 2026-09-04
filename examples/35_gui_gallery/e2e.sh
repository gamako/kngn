#!/usr/bin/env bash
# Replay the gallery's menu and dialog migration contract and retain framebuffer snapshots.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gui-gallery-e2e.XXXXXX")
REPLAY_OUT="$WORK/replay"
mkdir -p "$REPLAY_OUT"

command -v zig >/dev/null 2>&1 || {
    echo "[gui-gallery] zig not on PATH; run this inside the dev shell" >&2
    exit 1
}

echo "[gui-gallery] replay output: $REPLAY_OUT"
cd "$ROOT"
KNGN_HEADLESS=1 \
KNGN_HARNESS_MANUAL_CLOCK=1 \
KNGN_HARNESS_SCRIPT="$SCRIPT_DIR/e2e.txt" \
KNGN_HARNESS_OUT="$REPLAY_OUT" \
zig build run-example_35

echo "[gui-gallery] replay snapshots:"
find "$REPLAY_OUT" -type f -name '*.png' -print | sort
shots=$(find "$REPLAY_OUT" -type f -name '*.png' | wc -l | tr -d ' ')
if [[ "$shots" -lt 12 ]]; then
    echo "[gui-gallery] expected at least 12 snapshots, got $shots" >&2
    exit 1
fi
