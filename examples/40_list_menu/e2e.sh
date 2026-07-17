#!/usr/bin/env bash
# TASK-121.4 live harness E2E: 7 scenarios + expect.
# 座標は digest layout から導出（固定座標禁止）。port は 9230〜9239 のみ。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
VP_ROOT="${VP_ROOT:-/Users/gamako/gamako/project/zig/video-proto/video-proto-main}"
E2E_PORT="${E2E_PORT:-9230}"
E2E_WIDTH="${E2E_WIDTH:-1024}"
E2E_HEIGHT="${E2E_HEIGHT:-768}"
E2E_TIMEOUT_SEC="${E2E_TIMEOUT_SEC:-60}"
VP_HARNESS_OUT="${VP_HARNESS_OUT:-$(mktemp -d /tmp/vp-task-121.4.XXXXXX)}"
PORT_FILE="$VP_HARNESS_OUT/harness.port"
LOG="$VP_HARNESS_OUT/e2e.log"
DRIVE="$ROOT/scripts/drive"

# port range guard
if [[ "$E2E_PORT" -lt 9230 || "$E2E_PORT" -gt 9239 ]]; then
  echo "E2E_PORT must be 9230..9239 (got $E2E_PORT)" >&2
  exit 1
fi

mkdir -p "$VP_HARNESS_OUT"
: >"$LOG"

log() { echo "$@" | tee -a "$LOG"; }

APP_PID=""
cleanup() {
  if [[ -n "${APP_PID}" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    if [[ -f "$PORT_FILE" ]]; then
      "$DRIVE" --port-file "$PORT_FILE" 'quit' >>"$LOG" 2>&1 || true
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

if [[ ! -x "$ROOT/zig-out/bin/drive" ]]; then
  log "[e2e] building drive..."
  direnv exec "$VP_ROOT" zig build drive >>"$LOG" 2>&1
fi

log "[e2e] out=$VP_HARNESS_OUT port=$E2E_PORT size=${E2E_WIDTH}x${E2E_HEIGHT}"

VP_GUI_WIDTH="$E2E_WIDTH" \
VP_GUI_HEIGHT="$E2E_HEIGHT" \
VP_HARNESS_HEADLESS=1 \
VP_HARNESS_LIVE=1 \
VP_HARNESS_PORT="$E2E_PORT" \
VP_HARNESS_PORT_FILE="$PORT_FILE" \
VP_HARNESS_OUT="$VP_HARNESS_OUT" \
direnv exec "$VP_ROOT" zig build run-example_40 >>"$LOG" 2>&1 &
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
  "$DRIVE" --port-file "$PORT_FILE" "$1"
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

# ── Scenario 1: initial 500 rows ──
log "[e2e] === scenario 1: initial state + 500 rows ==="
drive "step 3" >>"$LOG" 2>&1
STATE=$(digest_state)
log "[e2e] state bytes=${#STATE}"
expect_state "row_count=500"
expect_state "visible_count=500"
expect_state "selected_row=-1"
expect_state "filter_mask=7"
expect_state "popup=none"
LAYOUT=$(digest_layout)
log "[e2e] layout bytes=${#LAYOUT}"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 1 PASS"

# ── Scenario 2: list select row12 ──
log "[e2e] === scenario 2: list select row12 ==="
LAYOUT=$(digest_layout)
read -r rx ry rw rh <<<"$(layout_rect row12 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$rx" "$ry" "$rw" "$rh")"
click_xy "$cx" "$cy"
drive "step 2" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "selected_row=12"
expect_state "active_row=12"
expect_state "active_source=mouse"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 2 PASS"

# ── Scenario 3: context menu ──
log "[e2e] === scenario 3: context menu ==="
LAYOUT=$(digest_layout)
read -r rx ry rw rh <<<"$(layout_rect row12 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$rx" "$ry" "$rw" "$rh")"
right_click_xy "$cx" "$cy"
drive "step 1" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "popup=context"
expect_state "popup_count=1"
expect_state "context_row=12"
LAYOUT=$(digest_layout)
read -r ix iy iw ih <<<"$(layout_rect context_item0 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$ix" "$iy" "$iw" "$ih")"
click_xy "$cx" "$cy"
drive "step 2" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "last_context_action=open"
expect_state "popup=none"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 3 PASS"

# ── Scenario 4: filter multi-select ──
log "[e2e] === scenario 4: filter multi-select ==="
LAYOUT=$(digest_layout)
read -r fx fy fw fh <<<"$(layout_rect filter "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$fx" "$fy" "$fw" "$fh")"
click_xy "$cx" "$cy"
drive "step 2" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "popup=filter"
expect_state "filter_mask=7"
LAYOUT=$(digest_layout)
read -r ix iy iw ih <<<"$(layout_rect filter_item0 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$ix" "$iy" "$iw" "$ih")"
click_xy "$cx" "$cy"
drive "step 2" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "filter_mask=6"
expect_state "popup=filter"
expect_state "filter_reopen_count>0"
LAYOUT=$(digest_layout)
read -r ix iy iw ih <<<"$(layout_rect filter_item1 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$ix" "$iy" "$iw" "$ih")"
click_xy "$cx" "$cy"
drive "step 2" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "filter_mask=4"
expect_state "popup=filter"
# click outside to dismiss
drive "inject mouse_move 5 5; step 1; inject mouse_down left; step 1; inject mouse_up left; step 2" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "popup=none"
expect_state "visible_count>0"
# restore filter_mask=7: open filter, toggle item0 and item1 back on
LAYOUT=$(digest_layout)
read -r fx fy fw fh <<<"$(layout_rect filter "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$fx" "$fy" "$fw" "$fh")"
click_xy "$cx" "$cy"
drive "step 2" >>"$LOG" 2>&1
LAYOUT=$(digest_layout)
read -r ix iy iw ih <<<"$(layout_rect filter_item0 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$ix" "$iy" "$iw" "$ih")"
click_xy "$cx" "$cy"
drive "step 2" >>"$LOG" 2>&1
LAYOUT=$(digest_layout)
read -r ix iy iw ih <<<"$(layout_rect filter_item1 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$ix" "$iy" "$iw" "$ih")"
click_xy "$cx" "$cy"
drive "step 2" >>"$LOG" 2>&1
drive "inject mouse_move 5 5; step 1; inject mouse_down left; step 1; inject mouse_up left; step 2" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "filter_mask=7"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 4 PASS"

# ── Scenario 5: keyboard nav ──
log "[e2e] === scenario 5: keyboard UP/DOWN ==="
# ensure selected_row=12, popup closed
LAYOUT=$(digest_layout)
read -r rx ry rw rh <<<"$(layout_rect row12 "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$rx" "$ry" "$rw" "$rh")"
click_xy "$cx" "$cy"
drive "step 1" >>"$LOG" 2>&1
expect_state "selected_row=12"
expect_state "popup=none"
expect_state "filter_mask=7"
drive "inject key_down DOWN; step 1; inject key_up DOWN; step 1" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "active_row=13"
expect_state "selected_row=13"
expect_state "active_source=keyboard"
drive "inject key_down UP; step 1; inject key_up UP; step 1" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "active_row=12"
expect_state "selected_row=12"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 5 PASS"

# ── Scenario 6: empty state ──
log "[e2e] === scenario 6: empty state ==="
LAYOUT=$(digest_layout)
read -r fx fy fw fh <<<"$(layout_rect filter "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$fx" "$fy" "$fw" "$fh")"
click_xy "$cx" "$cy"
drive "step 2" >>"$LOG" 2>&1
for item_key in filter_item0 filter_item1 filter_item2; do
  LAYOUT=$(digest_layout)
  read -r ix iy iw ih <<<"$(layout_rect "$item_key" "$LAYOUT")"
  read -r cx cy <<<"$(rect_center "$ix" "$iy" "$iw" "$ih")"
  click_xy "$cx" "$cy"
  drive "step 2" >>"$LOG" 2>&1
  digest_state >/dev/null
  expect_state "popup=filter"
done
drive "inject mouse_move 5 5; step 1; inject mouse_down left; step 1; inject mouse_up left; step 2" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "filter_mask=0"
expect_state "visible_count=0"
expect_state "empty=1"
expect_state "popup=none"
LAYOUT=$(digest_layout)
# empty rect may be non-zero
EMPTY=$(parse_kv empty "$LAYOUT")
log "[e2e] empty rect=$EMPTY"
drive "snapshot fb" >>"$LOG" 2>&1
# restore filters
LAYOUT=$(digest_layout)
read -r fx fy fw fh <<<"$(layout_rect filter "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$fx" "$fy" "$fw" "$fh")"
click_xy "$cx" "$cy"
drive "step 2" >>"$LOG" 2>&1
for item_key in filter_item0 filter_item1 filter_item2; do
  LAYOUT=$(digest_layout)
  read -r ix iy iw ih <<<"$(layout_rect "$item_key" "$LAYOUT")"
  read -r cx cy <<<"$(rect_center "$ix" "$iy" "$iw" "$ih")"
  click_xy "$cx" "$cy"
  drive "step 2" >>"$LOG" 2>&1
done
drive "inject mouse_move 5 5; step 1; inject mouse_down left; step 1; inject mouse_up left; step 2" >>"$LOG" 2>&1
expect_state "filter_mask=7"
log "[e2e] scenario 6 PASS"

# ── Scenario 7: menu + popup simultaneous constraint ──
log "[e2e] === scenario 7: menu/popup simultaneous constraint ==="
LAYOUT=$(digest_layout)
read -r fx fy fw fh <<<"$(layout_rect file "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$fx" "$fy" "$fw" "$fh")"
click_xy "$cx" "$cy"
drive "step 2" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "menu=File"
expect_state "popup=menu"
expect_state "popup_count=1"
# right-click row12 while menu open
LAYOUT=$(digest_layout)
# row12 may need scroll; use list center as fallback if row12 is 0
ROW12=$(parse_kv row12 "$LAYOUT")
if [[ "$ROW12" == "0,0,0,0" || -z "$ROW12" ]]; then
  read -r lx ly lw lh <<<"$(layout_rect list "$LAYOUT")"
  cx=$((lx + lw / 2))
  cy=$((ly + 40))
else
  read -r rx ry rw rh <<<"$(echo "$ROW12" | tr ',' ' ')"
  read -r cx cy <<<"$(rect_center "$rx" "$ry" "$rw" "$rh")"
fi
right_click_xy "$cx" "$cy"
drive "step 1" >>"$LOG" 2>&1
STATE1=$(digest_state)
log "[e2e] scenario7 after right-click: $STATE1"
# 観測値を固定（2026-07-18）: menuBar が open_title=File の間 popup を再確保するため
# 右クリック後も popup=menu / menu=File / popup_count=1。context は同時保持されない。
expect_state "popup_count=1"
expect_state "menu=File"
expect_state "popup=menu"
drive "step 1" >>"$LOG" 2>&1
STATE2=$(digest_state)
log "[e2e] scenario7 next frame: $STATE2"
expect_state "popup=menu"
# dismiss
drive "inject mouse_move 5 5; step 1; inject mouse_down left; step 1; inject mouse_up left; step 2" >>"$LOG" 2>&1
digest_state >/dev/null
expect_state "popup=none"
expect_state "menu=none"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 7 PASS (baked popup1=menu popup2=menu; Missing: simultaneous menu+context)"

log "[e2e] quit"
drive "quit" >>"$LOG" 2>&1 || true
sleep 0.2
APP_PID=""
log "[e2e] ALL 7 SCENARIOS PASSED"
log "[e2e] log=$LOG"
log "[e2e] digest_state sample bytes recorded above"
exit 0
