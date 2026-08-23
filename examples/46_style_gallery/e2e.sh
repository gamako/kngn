#!/usr/bin/env bash
# Run the deterministic replay and the manual-clock live protocol for the showcase.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KNGN_ROOT="${KNGN_ROOT:-/Users/gamako/gamako/project/zig/video-proto/kngn}"
KNGN="$KNGN_ROOT/scripts/kngn"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/style-gallery-e2e.XXXXXX")
REPLAY_OUT="$WORK/replay"
LIVE_OUT="$WORK/live"
PORT_FILE="$LIVE_OUT/harness.port"
mkdir -p "$REPLAY_OUT" "$LIVE_OUT"

export ZIG_LOCAL_CACHE_DIR="$WORK/zig-cache"
export ZIG_GLOBAL_CACHE_DIR="$WORK/zig-global-cache"

log() { printf '%s\n' "$*"; }

log "[style-gallery] replay output: $REPLAY_OUT"
KNGN_HEADLESS=1 \
KNGN_HARNESS_MANUAL_CLOCK=1 \
KNGN_HARNESS_SCRIPT="$SCRIPT_DIR/e2e.txt" \
KNGN_HARNESS_OUT="$REPLAY_OUT" \
direnv exec "$KNGN_ROOT" zig build run-example_46

app_pid=""
cleanup() {
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
        if [[ -f "$PORT_FILE" ]]; then
            "$KNGN" ctl --port-file "$PORT_FILE" 'quit' >/dev/null 2>&1 || true
        fi
        for _ in $(seq 1 100); do
            kill -0 "$app_pid" 2>/dev/null || break
            sleep 0.05
        done
        if kill -0 "$app_pid" 2>/dev/null; then
            kill "$app_pid" 2>/dev/null || true
        fi
        wait "$app_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

log "[style-gallery] live output: $LIVE_OUT"
KNGN_HEADLESS=1 \
KNGN_HARNESS_LISTEN= \
KNGN_HARNESS_MANUAL_CLOCK=1 \
KNGN_HARNESS_PORT_FILE="$PORT_FILE" \
KNGN_HARNESS_OUT="$LIVE_OUT" \
direnv exec "$KNGN_ROOT" zig build run-example_46 >"$LIVE_OUT/app.log" 2>&1 &
app_pid=$!

for _ in $(seq 1 6000); do
    [[ -f "$PORT_FILE" ]] && break
    if ! kill -0 "$app_pid" 2>/dev/null; then
        tail -n 80 "$LIVE_OUT/app.log" >&2 || true
        exit 1
    fi
    sleep 0.05
done
[[ -f "$PORT_FILE" ]] || { tail -n 80 "$LIVE_OUT/app.log" >&2 || true; exit 1; }

while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="$line"
    [[ -z "$trimmed" || "${trimmed:0:1}" == "#" ]] && continue
    response=$("$KNGN" ctl --port-file "$PORT_FILE" "$trimmed")
    log "[live] $response"
    if [[ "$response" == *" fail"* ]]; then
        exit 1
    fi
    [[ "$trimmed" == "quit" ]] && break
done < "$SCRIPT_DIR/e2e.txt"

app_pid=""
log "[style-gallery] replay snapshots:"
find "$REPLAY_OUT" -type f -name '*.png' -print | sort
log "[style-gallery] live snapshots:"
find "$LIVE_OUT" -type f -name '*.png' -print | sort
