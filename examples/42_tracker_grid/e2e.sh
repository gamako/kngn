#!/usr/bin/env bash
# live harness E2E: a handful of scenarios + expect.
# Derive coordinates from digest layout (no hard-coded coords). Ports 9240-9249 only.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KNGN_ROOT="${KNGN_ROOT:-$ROOT}"
E2E_PORT="${E2E_PORT:-9240}"
E2E_WIDTH="${E2E_WIDTH:-1024}"
E2E_HEIGHT="${E2E_HEIGHT:-768}"
E2E_TIMEOUT_SEC="${E2E_TIMEOUT_SEC:-60}"
KNGN_HARNESS_OUT="${KNGN_HARNESS_OUT:-$(mktemp -d /tmp/lane-b3-tracker.XXXXXX)}"
PORT_FILE="$KNGN_HARNESS_OUT/harness.port"
LOG="$KNGN_HARNESS_OUT/e2e.log"
KNGN="$ROOT/scripts/kngn"

# port range guard
if [[ "$E2E_PORT" -lt 9240 || "$E2E_PORT" -gt 9249 ]]; then
  echo "E2E_PORT must be 9240..9249 (got $E2E_PORT)" >&2
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
direnv exec "$KNGN_ROOT" zig build run-example_42 >>"$LOG" 2>&1 &
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

# Slider knob center x from the track rect + a 0..1 fraction (style default knob_w=10, the same
# assumption examples/39_settings_shell/e2e.sh's slider_knob_xy makes). `sliderCore` only starts a
# drag from a press on the knob itself (not anywhere on the track), so a click must land here
# first, not at an arbitrary point along the track.
slider_knob_x() {
  local x="$1" w="$2" frac="$3"
  awk -v x="$x" -v w="$w" -v frac="$frac" 'BEGIN {
    knob_w = 10
    lo = x + knob_w / 2
    span = w - knob_w
    if (span < 1) span = 1
    printf "%d", lo + frac * span
  }'
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
expect_state "active_pattern=0"
expect_state "selected_track=0"
expect_state "muted_mask=0"
expect_state "solo_mask=0"
expect_state "popup=none"
LAYOUT=$(digest_layout)
log "[e2e] layout bytes=${#LAYOUT}"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 1 PASS"

# ── Scenario 2: pattern tab switch ──
log "[e2e] === scenario 2: pattern tab switch ==="
LAYOUT=$(digest_layout)
read -r tx ty tw th <<<"$(layout_rect tab1 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$tx" "$ty" "$tw" "$th")"
click_xy "$cx" "$cy"
drive "step 2" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "active_pattern=1"
LAYOUT=$(digest_layout)
read -r tx ty tw th <<<"$(layout_rect tab0 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$tx" "$ty" "$tw" "$th")"
click_xy "$cx" "$cy"
drive "step 2" >>"$LOG" 2>&1
expect_state "active_pattern=0"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 2 PASS"

# ── Scenario 3: track select (mouse) + keyboard nav ──
log "[e2e] === scenario 3: track select + keyboard nav ==="
LAYOUT=$(digest_layout)
read -r rx ry rw rh <<<"$(layout_rect track_long "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$rx" "$ry" "$rw" "$rh")"
click_xy "$cx" "$cy"
drive "step 2" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "selected_track=6"
expect_state "select_source=mouse"
expect_state "ellipsis_used=1"
drive "inject key_down UP; step 1; inject key_up UP; step 1" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "selected_track=5"
expect_state "select_source=keyboard"
drive "inject key_down DOWN; step 1; inject key_up DOWN; step 1" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "selected_track=6"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 3 PASS"

# ── Scenario 4: step grid toggle ──
log "[e2e] === scenario 4: step grid toggle ==="
LAYOUT=$(digest_layout)
read -r rx ry rw rh <<<"$(layout_rect track0 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$rx" "$ry" "$rw" "$rh")"
click_xy "$cx" "$cy"
drive "step 1" >>"$LOG" 2>&1
expect_state "selected_track=0"
LAYOUT=$(digest_layout)
read -r sx sy sw sh <<<"$(layout_rect cell_t0_s0 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$sx" "$sy" "$sw" "$sh")"
STATE=$(digest_state)
MASK0=$(parse_kv step_t0 "$STATE")
click_xy "$cx" "$cy"
drive "step 2" >>"$LOG" 2>&1
STATE=$(digest_state)
MASK1=$(parse_kv step_t0 "$STATE")
if [[ "$MASK0" == "$MASK1" ]]; then
  log "[e2e] FAIL: step_t0 mask did not change ($MASK0 == $MASK1)"
  exit 1
fi
log "[e2e] ok step_t0 mask changed ($MASK0 -> $MASK1)"
# toggle back
click_xy "$cx" "$cy"
drive "step 2" >>"$LOG" 2>&1
expect_state "step_t0=$MASK0"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 4 PASS"

# ── Scenario 5: mute disables Volume/Pan (beginDisabled), context menu toggles checked ──
log "[e2e] === scenario 5: mute + disabled + context menu ==="
LAYOUT=$(digest_layout)
read -r rx ry rw rh <<<"$(layout_rect track0 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$rx" "$ry" "$rw" "$rh")"
right_click_xy "$cx" "$cy"
drive "step 1" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "popup=context"
expect_state "context_track=0"
LAYOUT=$(digest_layout)
read -r ix iy iw ih <<<"$(layout_rect context_item0 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$ix" "$iy" "$iw" "$ih")"
click_xy "$cx" "$cy"
drive "step 2" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "muted_mask=1"
# keep_open_on_select: the popup stays open after toggling Mute (checked reflects the new state)
expect_state "popup=context"
# dismiss via outside click
drive "inject mouse_move 5 5; step 1; inject mouse_down left; step 1; inject mouse_up left; step 2" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "popup=none"

# Volume drag while muted: expect no change (beginDisabled rejects the drag). Start the press
# exactly on the current knob position (frac = VOL0, min=0 max=1) -- clicking elsewhere on the
# track never starts a drag in the first place, disabled or not, so that alone would not
# distinguish "rejected because disabled" from "missed the knob".
LAYOUT=$(digest_layout)
STATE=$(digest_state)
VOL0=$(parse_kv volume "$STATE")
read -r vx vy vw vh <<<"$(layout_rect volume_slider "$LAYOUT")"
KX=$(slider_knob_x "$vx" "$vw" "$VOL0")
RIGHT_X=$((vx + vw - 2))
CY=$((vy + vh / 2))
drive "inject mouse_move $KX $CY; step 1; inject mouse_down left; step 1; inject mouse_move $RIGHT_X $CY; step 2; inject mouse_up left; step 1" >>"$LOG" 2>&1
STATE=$(digest_state)
VOL1=$(parse_kv volume "$STATE")
if [[ "$VOL0" != "$VOL1" ]]; then
  log "[e2e] FAIL: volume changed while muted/disabled ($VOL0 -> $VOL1)"
  exit 1
fi
log "[e2e] ok volume unchanged while muted ($VOL0)"

# Unmute via context menu, then the same drag does change Volume.
LAYOUT=$(digest_layout)
read -r rx ry rw rh <<<"$(layout_rect track0 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$rx" "$ry" "$rw" "$rh")"
right_click_xy "$cx" "$cy"
drive "step 1" >>"$LOG" 2>&1
expect_state "popup=context"
LAYOUT=$(digest_layout)
read -r ix iy iw ih <<<"$(layout_rect context_item0 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$ix" "$iy" "$iw" "$ih")"
click_xy "$cx" "$cy"
drive "step 2" >>"$LOG" 2>&1
expect_state "muted_mask=0"
drive "inject mouse_move 5 5; step 1; inject mouse_down left; step 1; inject mouse_up left; step 2" >>"$LOG" 2>&1
expect_state "popup=none"

LAYOUT=$(digest_layout)
STATE=$(digest_state)
VOL_BEFORE=$(parse_kv volume "$STATE")
read -r vx vy vw vh <<<"$(layout_rect volume_slider "$LAYOUT")"
KX=$(slider_knob_x "$vx" "$vw" "$VOL_BEFORE")
RIGHT_X=$((vx + vw - 2))
CY=$((vy + vh / 2))
drive "inject mouse_move $KX $CY; step 1; inject mouse_down left; step 1; inject mouse_move $RIGHT_X $CY; step 2; inject mouse_up left; step 1" >>"$LOG" 2>&1
STATE=$(digest_state)
VOL2=$(parse_kv volume "$STATE")
if [[ "$VOL2" == "$VOL_BEFORE" ]]; then
  log "[e2e] FAIL: volume did not change once unmuted ($VOL2 == $VOL_BEFORE)"
  exit 1
fi
log "[e2e] ok volume changed once unmuted ($VOL_BEFORE -> $VOL2)"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 5 PASS"

log "[e2e] ALL SCENARIOS PASS out=$KNGN_HARNESS_OUT"
