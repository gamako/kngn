#!/usr/bin/env bash
# Run the deterministic replay for the layout catalog and report the snapshots.
#
# Needs `zig` on PATH, which the repository's dev shell provides:
#   nix develop --command bash examples/10_gui_layout/e2e.sh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gui-layout-e2e.XXXXXX")
REPLAY_OUT="$WORK/replay"
mkdir -p "$REPLAY_OUT"

command -v zig >/dev/null 2>&1 || {
    echo "[gui-layout] zig not on PATH; run this inside the dev shell" >&2
    exit 1
}

export ZIG_LOCAL_CACHE_DIR="$WORK/zig-cache"
export ZIG_GLOBAL_CACHE_DIR="$WORK/zig-global-cache"

echo "[gui-layout] replay output: $REPLAY_OUT"
cd "$ROOT"
KNGN_HEADLESS=1 \
KNGN_HARNESS_MANUAL_CLOCK=1 \
KNGN_HARNESS_SCRIPT="$SCRIPT_DIR/e2e.txt" \
KNGN_HARNESS_OUT="$REPLAY_OUT" \
zig build run-example_10

echo "[gui-layout] replay snapshots:"
find "$REPLAY_OUT" -type f -name '*.png' -print | sort
# `snapshot` warns and continues rather than failing, so an empty output directory
# would otherwise pass silently.
shots=$(find "$REPLAY_OUT" -type f -name '*.png' | wc -l | tr -d ' ')
if [[ "$shots" -lt 2 ]]; then
    echo "[gui-layout] expected at least 2 snapshots, got $shots" >&2
    exit 1
fi
