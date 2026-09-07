#!/usr/bin/env bash
# Replay the gallery's menu and dialog migration contract and retain framebuffer snapshots.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gui-gallery-e2e.XXXXXX")
# One directory per replay: snapshot file names restart with each run, so a shared directory
# would have the second theme overwrite the first one's frames.
DARK_OUT="$WORK/dark"
LIGHT_OUT="$WORK/light"
mkdir -p "$DARK_OUT" "$LIGHT_OUT"

command -v zig >/dev/null 2>&1 || {
    echo "[gui-gallery] zig not on PATH; run this inside the dev shell" >&2
    exit 1
}

echo "[gui-gallery] replay output: $WORK"
cd "$ROOT"
KNGN_HEADLESS=1 \
KNGN_HARNESS_MANUAL_CLOCK=1 \
KNGN_HARNESS_SCRIPT="$SCRIPT_DIR/e2e.txt" \
KNGN_HARNESS_OUT="$DARK_OUT" \
zig build run-example_35

# The same floating surfaces on a light ground. Their shadows are the theme's, so a review of
# one theme is not a review of the other.
KNGN_HEADLESS=1 \
KNGN_HARNESS_MANUAL_CLOCK=1 \
KNGN_HARNESS_SCRIPT="$SCRIPT_DIR/e2e_light.txt" \
KNGN_HARNESS_OUT="$LIGHT_OUT" \
zig build run-example_35

echo "[gui-gallery] dark snapshots:"
find "$DARK_OUT" -type f -name '*.png' -print | sort
echo "[gui-gallery] light snapshots:"
find "$LIGHT_OUT" -type f -name '*.png' -print | sort
# Counted per script: a shortfall in one replay would otherwise be hidden by the other's frames.
dark_shots=$(find "$DARK_OUT" -type f -name '*.png' | wc -l | tr -d ' ')
if [[ "$dark_shots" -lt 12 ]]; then
    echo "[gui-gallery] expected at least 12 dark snapshots, got $dark_shots" >&2
    exit 1
fi
light_shots=$(find "$LIGHT_OUT" -type f -name '*.png' | wc -l | tr -d ' ')
if [[ "$light_shots" -lt 5 ]]; then
    echo "[gui-gallery] expected at least 5 light snapshots, got $light_shots" >&2
    exit 1
fi
