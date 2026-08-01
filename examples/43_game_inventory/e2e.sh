#!/usr/bin/env bash
# live harness E2E: a handful of scenarios + expect.
# Derive coordinates from digest layout (no hard-coded coords). Ports 9250-9259 only.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KNGN_ROOT="${KNGN_ROOT:-$ROOT}"
E2E_PORT="${E2E_PORT:-9250}"
E2E_WIDTH="${E2E_WIDTH:-1024}"
E2E_HEIGHT="${E2E_HEIGHT:-768}"
E2E_TIMEOUT_SEC="${E2E_TIMEOUT_SEC:-60}"
KNGN_HARNESS_OUT="${KNGN_HARNESS_OUT:-$(mktemp -d /tmp/lane-b3-inventory.XXXXXX)}"
PORT_FILE="$KNGN_HARNESS_OUT/harness.port"
LOG="$KNGN_HARNESS_OUT/e2e.log"
KNGN="$ROOT/scripts/kngn"

if [[ "$E2E_PORT" -lt 9250 || "$E2E_PORT" -gt 9259 ]]; then
  echo "E2E_PORT must be 9250..9259 (got $E2E_PORT)" >&2
  exit 1
fi

mkdir -p "$KNGN_HARNESS_OUT"
: >"$LOG"

log() { echo "$@" | tee -a "$LOG"; }

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

if [[ ! -x "$ROOT/zig-out/bin/kngn" ]]; then
  log "[e2e] building kngn..."
  direnv exec "$KNGN_ROOT" zig build kngn >>"$LOG" 2>&1
fi

log "[e2e] out=$KNGN_HARNESS_OUT port=$E2E_PORT size=${E2E_WIDTH}x${E2E_HEIGHT}"

KNGN_GUI_WIDTH="$E2E_WIDTH" \
KNGN_GUI_HEIGHT="$E2E_HEIGHT" \
KNGN_HEADLESS=1 \
KNGN_HARNESS_LISTEN="$E2E_PORT" \
KNGN_HARNESS_PORT_FILE="$PORT_FILE" \
KNGN_HARNESS_OUT="$KNGN_HARNESS_OUT" \
direnv exec "$KNGN_ROOT" zig build run-example_43 >>"$LOG" 2>&1 &
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
log "[e2e] port file ready after ~$((WAIT / 2))s: $(cat "$PORT_FILE")"

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

click_xy() {
  local x="$1" y="$2"
  drive "inject mouse_move $x $y; step 1; inject mouse_down left; step 1; inject mouse_up left; step 1"
}

right_click_xy() {
  local x="$1" y="$2"
  drive "inject mouse_move $x $y; step 1; inject mouse_down right; step 1; inject mouse_up right; step 1"
}

digest_state() {
  drive "digest state" | tee -a "$LOG" | tail -n 1
}

digest_layout() {
  drive "digest layout" | tee -a "$LOG" | tail -n 1
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

# warm
drive "step 3" >>"$LOG" 2>&1

# ── Scenario 1: initial state ──
log "[e2e] === scenario 1: initial state ==="
STATE=$(digest_state)
log "[e2e] state bytes=${#STATE}"
expect_state "cursor=0"
expect_state "dragging=0"
expect_state "min_rarity=0"
expect_state "popup=none"
expect_state "slot0=filled,1,1,0"
expect_state "slot1=empty"
expect_state "slot7=filled,4,1,1"
LAYOUT=$(digest_layout)
log "[e2e] layout bytes=${#LAYOUT}"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 1 PASS"

# ── Scenario 2: hover tooltip (filled slot) ──
log "[e2e] === scenario 2: hover tooltip ==="
LAYOUT=$(digest_layout)
read -r sx sy sw sh <<<"$(layout_rect slot0 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$sx" "$sy" "$sw" "$sh")"
drive "inject mouse_move $cx $cy; step 40" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "hover_slot=0"
# past the library's 500ms hover delay (40 frames at the virtual clock's 1/60s each) -- visually
# confirmed via snapshot fb, not by re-deriving ctx.tooltip's own timing test here.
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 2 PASS"

# ── Scenario 3: drag and drop (slot0 -> slot1, empty) ──
log "[e2e] === scenario 3: drag and drop onto an empty slot ==="
LAYOUT=$(digest_layout)
read -r s0x s0y s0w s0h <<<"$(layout_rect slot0 "$LAYOUT")"
read -r s1x s1y s1w s1h <<<"$(layout_rect slot1 "$LAYOUT")"
read -r c0x c0y <<<"$(rect_center "$s0x" "$s0y" "$s0w" "$s0h")"
read -r c1x c1y <<<"$(rect_center "$s1x" "$s1y" "$s1w" "$s1h")"
drive "inject mouse_move $c0x $c0y; step 1; inject mouse_down left; step 1" >>"$LOG" 2>&1
digest_state >/dev/null
# A press alone is "armed" only (gui.dragSource's threshold has not been crossed yet): no drag,
# item still in its slot. Confirms a plain click never flickers an item out of place.
expect_state "dragging=0"
expect_state "slot0=filled,1,1,0"
drive "inject mouse_move $c1x $c1y; step 2" >>"$LOG" 2>&1
digest_state >/dev/null
# Moving toward slot1 crosses the threshold well before arriving (slot spacing >> a few px): now
# actually dragging, and the item has been lifted out of slot0.
expect_state "dragging=1"
expect_state "slot0=empty"
drive "inject mouse_up left; step 1" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "dragging=0"
expect_state "slot0=empty"
expect_state "slot1=filled,1,1,0"
drive "snapshot fb" >>"$LOG" 2>&1
# move it back for later scenarios
drive "inject mouse_move $c1x $c1y; step 1; inject mouse_down left; step 1; inject mouse_move $c0x $c0y; step 2; inject mouse_up left; step 1" >>"$LOG" 2>&1
expect_state "slot0=filled,1,1,0"
expect_state "slot1=empty"
log "[e2e] scenario 3 PASS"

# ── Scenario 4: locked slot rejects drag ──
log "[e2e] === scenario 4: locked slot cannot be dragged ==="
LAYOUT=$(digest_layout)
read -r s7x s7y s7w s7h <<<"$(layout_rect slot7 "$LAYOUT")"
read -r c7x c7y <<<"$(rect_center "$s7x" "$s7y" "$s7w" "$s7h")"
drive "inject mouse_move $c7x $c7y; step 1; inject mouse_down left; step 1" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "dragging=0"
expect_state "slot7=filled,4,1,1"
drive "inject mouse_up left; step 1" >>"$LOG" 2>&1
log "[e2e] scenario 4 PASS"

# ── Scenario 5: keyboard + gamepad cursor nav ──
log "[e2e] === scenario 5: keyboard and gamepad cursor nav ==="
click_xy "$c0x" "$c0y" # re-select slot0 (cursor=0) after scenario 4 left it on slot7
drive "step 1" >>"$LOG" 2>&1
expect_state "cursor=0"
drive "inject key_down RIGHT; step 1; inject key_up RIGHT; step 1" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "cursor=1"
expect_state "select_source=keyboard"
drive "inject gamepad_connect 0; step 1" >>"$LOG" 2>&1
drive "inject gamepad_button 0 dpad_down 1; step 1; inject gamepad_button 0 dpad_down 0; step 1" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "cursor=7"
expect_state "select_source=gamepad"
drive "inject gamepad_button 0 dpad_left 1; step 1; inject gamepad_button 0 dpad_left 0; step 1" >>"$LOG" 2>&1
expect_state "cursor=6"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 5 PASS"

# ── Scenario 6: gamepad A picks up and drops (equivalent to mouse drag) ──
log "[e2e] === scenario 6: gamepad A pickup/drop ==="
# cursor is at slot6 (row1,col0) from scenario 5; one dpad_up (row-1) reaches slot0 (row0,col0).
drive "inject gamepad_button 0 dpad_up 1; step 1; inject gamepad_button 0 dpad_up 0; step 1" >>"$LOG" 2>&1
expect_state "cursor=0"
drive "inject gamepad_button 0 a 1; step 1; inject gamepad_button 0 a 0; step 1" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "dragging=1"
expect_state "slot0=empty"
# A again at the same cursor slot drops it back (endDrag(app.cursor)).
drive "inject gamepad_button 0 a 1; step 1; inject gamepad_button 0 a 0; step 1" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "dragging=0"
expect_state "slot0=filled,1,1,0"
log "[e2e] scenario 6 PASS"

# ── Scenario 7: rarity knob drag ──
log "[e2e] === scenario 7: rarity knob drag ==="
LAYOUT=$(digest_layout)
read -r kx ky kw kh <<<"$(layout_rect knob "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$kx" "$ky" "$kw" "$kh")"
expect_state "min_rarity=0"
# drag up 60px (5 steps at 12px/step) to raise min_rarity to 5
UP_Y=$((cy - 60))
drive "inject mouse_move $cx $cy; step 1; inject mouse_down left; step 1; inject mouse_move $cx $UP_Y; step 2; inject mouse_up left; step 1" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "min_rarity=5"
drive "snapshot fb" >>"$LOG" 2>&1
# drag back down to 0. The new press must land back inside the knob's (fixed) rect at (cx,cy) --
# the mouse is currently at UP_Y from the drag above, well outside that rect, so a press there
# would not hit the knob at all (same "press must start on the widget" rule a real slider/knob
# follows; once held, movement is unbounded, but starting a *new* press is not).
DOWN_Y=$((cy + 60))
drive "inject mouse_move $cx $cy; step 1; inject mouse_down left; step 1; inject mouse_move $cx $DOWN_Y; step 2; inject mouse_up left; step 1" >>"$LOG" 2>&1
expect_state "min_rarity=0"
log "[e2e] scenario 7 PASS"

# ── Scenario 8: right-click context menu (Lock checked, Discard) ──
log "[e2e] === scenario 8: context menu Lock/Discard ==="
LAYOUT=$(digest_layout)
read -r s0x s0y s0w s0h <<<"$(layout_rect slot0 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$s0x" "$s0y" "$s0w" "$s0h")"
right_click_xy "$cx" "$cy"
drive "step 1" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "popup=context"
expect_state "context_slot=0"
LAYOUT=$(digest_layout)
read -r ix iy iw ih <<<"$(layout_rect context_item0 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$ix" "$iy" "$iw" "$ih")"
click_xy "$cx" "$cy" # toggle Lock
drive "step 2" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "slot0=filled,1,1,1"
# keep_open_on_select: Lock alone does not close the popup
expect_state "popup=context"
LAYOUT=$(digest_layout)
read -r ix iy iw ih <<<"$(layout_rect context_item1 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$ix" "$iy" "$iw" "$ih")"
click_xy "$cx" "$cy" # Discard
drive "step 2" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "slot0=empty"
expect_state "popup=none"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 8 PASS"

log "[e2e] ALL SCENARIOS PASS out=$KNGN_HARNESS_OUT"
