#!/usr/bin/env bash
# PanelHost E2E: replay + live (includes splitter drag)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KNGN_ROOT="${KNGN_ROOT:-/Users/gamako/gamako/project/zig/video-proto/video-proto-main}"
E2E_WIDTH="${E2E_WIDTH:-1024}"
E2E_HEIGHT="${E2E_HEIGHT:-768}"
E2E_TIMEOUT_SEC="${E2E_TIMEOUT_SEC:-60}"
KNGN="$ROOT/scripts/kngn"

log() { echo "$@"; }

# ── Replay ──────────────────────────────────────────────────
REPLAY_OUT=$(mktemp -d /tmp/t147-replay.XXXXXX)
REPLAY_PORT=/tmp/t147-replay.port
rm -f "$REPLAY_PORT"
mkdir -p "$REPLAY_OUT"
log "[e2e] === replay === out=$REPLAY_OUT"

KNGN_GUI_WIDTH="$E2E_WIDTH" \
KNGN_GUI_HEIGHT="$E2E_HEIGHT" \
KNGN_HEADLESS=1 \
KNGN_HARNESS_SCRIPT="$SCRIPT_DIR/e2e_replay.txt" \
KNGN_HARNESS_PORT_FILE="$REPLAY_PORT" \
KNGN_HARNESS_OUT="$REPLAY_OUT" \
direnv exec "$KNGN_ROOT" zig build run-example_41
log "[e2e] replay PASS"
log "[e2e] replay snapshots:"
ls -1 "$REPLAY_OUT"/*.png 2>/dev/null || true

# ── Live ────────────────────────────────────────────────────
LIVE_OUT=$(mktemp -d /tmp/t147-live.XXXXXX)
PORT_FILE=/tmp/t147-live.port
rm -f "$PORT_FILE"
LOG="$LIVE_OUT/e2e.log"
: >"$LOG"
log "[e2e] === live === out=$LIVE_OUT"

if [[ ! -x "$ROOT/zig-out/bin/kngn" ]]; then
  log "[e2e] building kngn..."
  direnv exec "$KNGN_ROOT" zig build kngn >>"$LOG" 2>&1
fi

APP_PID=""
cleanup() {
  if [[ -n "${APP_PID}" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    if [[ -f "$PORT_FILE" ]]; then
      "$KNGN" ctl --port-file "$PORT_FILE" 'quit' >>"$LOG" 2>&1 || true
      sleep 0.3
    fi
    if kill -0 "$APP_PID" 2>/dev/null; then
      kill "$APP_PID" 2>/dev/null || true
      wait "$APP_PID" 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT

cd "$ROOT"

KNGN_GUI_WIDTH="$E2E_WIDTH" \
KNGN_GUI_HEIGHT="$E2E_HEIGHT" \
KNGN_HEADLESS=1 \
KNGN_HARNESS_LISTEN= \
KNGN_HARNESS_PORT_FILE="$PORT_FILE" \
KNGN_HARNESS_OUT="$LIVE_OUT" \
direnv exec "$KNGN_ROOT" zig build run-example_41 >>"$LOG" 2>&1 &
APP_PID=$!
log "[e2e] started pid=$APP_PID"

WAIT_MAX=$((E2E_TIMEOUT_SEC * 2))
WAIT=0
while [[ ! -f "$PORT_FILE" ]]; do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    log "[e2e] FAIL: process died before port file"
    tail -n 80 "$LOG" || true
    exit 1
  fi
  if [[ "$WAIT" -ge "$WAIT_MAX" ]]; then
    log "[e2e] FAIL: timeout waiting for port file (${E2E_TIMEOUT_SEC}s)"
    exit 1
  fi
  sleep 0.5
  WAIT=$((WAIT + 1))
done
log "[e2e] port file ready: $(cat "$PORT_FILE")"

drive() {
  "$KNGN" ctl --port-file "$PORT_FILE" "$1"
}

parse_kv() {
  local key="$1"
  local line="$2"
  echo "$line" | sed -n "s/.*${key}=\\([^ ]*\\).*/\\1/p" | head -1
}

layout_rect() {
  local key="$1"
  local line="$2"
  local val
  val=$(parse_kv "$key" "$line")
  if [[ -z "$val" || "$val" == "0,0,0,0" || "$val" == "-1,-1,-1,-1" ]]; then
    log "[e2e] FAIL: missing layout key $key in: $line"
    exit 1
  fi
  echo "$val" | tr ',' ' '
}

rect_center() {
  local x="$1" y="$2" w="$3" h="$4"
  echo $((x + w / 2)) $((y + h / 2))
}

expect_state() {
  local expr="$1"
  local out
  out=$(drive "expect state $expr" | tee -a "$LOG")
  if echo "$out" | grep -q ' fail'; then
    log "[e2e] FAIL expect state $expr"
    log "$out"
    exit 1
  fi
  log "[e2e] ok expect state $expr"
}

digest_layout() {
  drive "digest layout" | tee -a "$LOG" | tail -n 1
}

# warm
drive "step 3" >>"$LOG" 2>&1

log "[e2e] === scenario 1: initial ==="
drive "digest state" >>"$LOG" 2>&1
expect_state "right_visible=1"
expect_state "center_w>400"
drive "snapshot fb" >>"$LOG" 2>&1
# copy with stable name for orchestrator
cp -f "$(ls -1t "$LIVE_OUT"/fb-*.png 2>/dev/null | head -1)" /tmp/t147-live-initial.png 2>/dev/null || \
  cp -f "$(ls -1t "$LIVE_OUT"/*.png 2>/dev/null | head -1)" /tmp/t147-live-initial.png
log "[e2e] scenario 1 PASS → /tmp/t147-live-initial.png"

log "[e2e] === scenario 2: toggle_slot right ==="
drive "action toggle_slot right; step 2" >>"$LOG" 2>&1
expect_state "right_visible=0"
expect_state "center_w>500"
drive "snapshot fb" >>"$LOG" 2>&1
cp -f "$(ls -1t "$LIVE_OUT"/*.png | head -1)" /tmp/t147-live-right-hidden.png
log "[e2e] scenario 2 PASS → /tmp/t147-live-right-hidden.png"

log "[e2e] === scenario 3: toggle_panel inspector ==="
# Restore right, then hide inspector
drive "action toggle_slot right; step 2; action toggle_panel Inspector; step 2" >>"$LOG" 2>&1
expect_state "inspector_visible=0"
drive "snapshot fb" >>"$LOG" 2>&1
cp -f "$(ls -1t "$LIVE_OUT"/*.png | head -1)" /tmp/t147-live-panel-hidden.png
log "[e2e] scenario 3 PASS → /tmp/t147-live-panel-hidden.png"

log "[e2e] === scenario 4: set_extent right 320 ==="
drive "action toggle_panel Inspector; step 1; action set_extent right 320; step 2" >>"$LOG" 2>&1
expect_state "right_extent=320"
drive "snapshot fb" >>"$LOG" 2>&1
cp -f "$(ls -1t "$LIVE_OUT"/*.png | head -1)" /tmp/t147-live-resized.png
log "[e2e] scenario 4 PASS → /tmp/t147-live-resized.png"

log "[e2e] === scenario 5: save/reset/restore ==="
drive "action save_state; action reset_state; step 2; action restore_state; step 2" >>"$LOG" 2>&1
expect_state "restored=1"
expect_state "right_extent=320"
drive "snapshot fb" >>"$LOG" 2>&1
cp -f "$(ls -1t "$LIVE_OUT"/*.png | head -1)" /tmp/t147-live-restored.png
log "[e2e] scenario 5 PASS → /tmp/t147-live-restored.png"

log "[e2e] === scenario 6: splitter drag ==="
LAYOUT=$(digest_layout)
read -r sx sy sw sh <<<"$(layout_rect split_right "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$sx" "$sy" "$sw" "$sh")"
BEFORE=$(parse_kv right_extent "$(drive "digest state" | tee -a "$LOG" | tail -n 1)")
log "[e2e] splitter at $cx,$cy extent_before=$BEFORE"
# drag left 60px → right extent grows (invert)
drive "inject mouse_move $cx $cy; step 1; inject mouse_down left; step 1; inject mouse_move $((cx - 60)) $cy; step 2; inject mouse_up left; step 2" >>"$LOG" 2>&1
AFTER=$(parse_kv right_extent "$(drive "digest state" | tee -a "$LOG" | tail -n 1)")
log "[e2e] extent_after=$AFTER"
if [[ -z "$AFTER" || "$AFTER" -le "$BEFORE" ]]; then
  log "[e2e] FAIL: splitter drag did not increase right_extent ($BEFORE -> $AFTER)"
  exit 1
fi
expect_state "right_extent>$BEFORE"
drive "snapshot fb" >>"$LOG" 2>&1
cp -f "$(ls -1t "$LIVE_OUT"/*.png | head -1)" /tmp/t147-live-splitter.png
log "[e2e] scenario 6 PASS → /tmp/t147-live-splitter.png"

log "[e2e] quit"
drive "quit" >>"$LOG" 2>&1 || true
APP_PID=""
log "[e2e] ALL SCENARIOS PASSED"
log "[e2e] replay_out=$REPLAY_OUT"
log "[e2e] live_out=$LIVE_OUT"
exit 0
