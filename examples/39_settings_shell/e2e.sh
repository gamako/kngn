#!/usr/bin/env bash
# TASK-121.3 live harness E2E: 7 scenarios + expect.
# 座標は digest layout から導出（固定座標禁止）。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
VP_ROOT="${VP_ROOT:-/Users/gamako/gamako/project/zig/video-proto/video-proto-main}"
E2E_PORT="${E2E_PORT:-9210}"
E2E_WIDTH="${E2E_WIDTH:-1024}"
E2E_HEIGHT="${E2E_HEIGHT:-768}"
VP_HARNESS_OUT="${VP_HARNESS_OUT:-$(mktemp -d /tmp/vp-task-121.3.XXXXXX)}"
PORT_FILE="$VP_HARNESS_OUT/harness.port"
LOG="$VP_HARNESS_OUT/e2e.log"
DRIVE="$ROOT/scripts/drive"

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

# ensure drive binary
if [[ ! -x "$ROOT/zig-out/bin/drive" ]]; then
  log "[e2e] building drive..."
  direnv exec "$VP_ROOT" zig build drive >>"$LOG" 2>&1
fi

log "[e2e] out=$VP_HARNESS_OUT port=$E2E_PORT size=${E2E_WIDTH}x${E2E_HEIGHT}"

# start app
VP_GUI_WIDTH="$E2E_WIDTH" \
VP_GUI_HEIGHT="$E2E_HEIGHT" \
VP_HEADLESS=1 \
VP_HARNESS_LISTEN="$E2E_PORT" \
VP_HARNESS_PORT_FILE="$PORT_FILE" \
VP_HARNESS_OUT="$VP_HARNESS_OUT" \
direnv exec "$VP_ROOT" zig build run-example_39 >>"$LOG" 2>&1 &
APP_PID=$!
log "[e2e] started pid=$APP_PID"

# wait for port file (timeout + process alive)
WAIT_MAX=120
WAIT=0
while [[ ! -f "$PORT_FILE" ]]; do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    log "[e2e] FAIL: process died before port file"
    tail -n 80 "$LOG" || true
    exit 1
  fi
  if [[ "$WAIT" -ge "$WAIT_MAX" ]]; then
    log "[e2e] FAIL: timeout waiting for port file ($WAIT_MAX s)"
    exit 1
  fi
  sleep 0.5
  WAIT=$((WAIT + 1))
done
log "[e2e] port file ready after ~$((WAIT / 2))s: $(cat "$PORT_FILE")"

# warm frames
"$DRIVE" --port-file "$PORT_FILE" 'step 3' >>"$LOG" 2>&1

drive() {
  "$DRIVE" --port-file "$PORT_FILE" "$1"
}

# parse key=value from digest line (first matching key)
# usage: parse_kv "selected" <<<"$line"
parse_kv() {
  local key="$1"
  local line="$2"
  # shellcheck disable=SC2001
  echo "$line" | sed -n "s/.*${key}=\\([^ ]*\\).*/\\1/p" | head -1
}

# layout rect: key=x,y,w,h -> prints four numbers
layout_rect() {
  local key="$1"
  local line="$2"
  local val
  val=$(parse_kv "$key" "$line")
  if [[ -z "$val" || "$val" == "-1,-1,-1,-1" ]]; then
    log "[e2e] FAIL: missing layout key $key in: $line"
    exit 1
  fi
  echo "$val" | tr ',' ' '
}

rect_center() {
  local x="$1" y="$2" w="$3" h="$4"
  echo $((x + w / 2)) $((y + h / 2))
}

# slider knob center from track rect + value (ui_scale style defaults: knob_w=10)
slider_knob_xy() {
  local x="$1" y="$2" w="$3" h="$4"
  local val="$5" minv="$6" maxv="$7"
  local knob_w=10
  local lo=$((x + knob_w / 2))
  local span=$((w - knob_w))
  if [[ "$span" -lt 1 ]]; then span=1; fi
  # bash integer math for frac
  local num=$(( (val - minv) * span ))
  local den=$((maxv - minv))
  local cx=$((lo + num / den))
  local cy=$((y + h / 2))
  echo "$cx" "$cy"
}

click_xy() {
  local x="$1" y="$2"
  drive "inject mouse_move $x $y; step 1; inject mouse_down left; step 1; inject mouse_up left; step 1"
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

# ── Scenario 1: General nav → Editor ──
log "[e2e] === scenario 1: nav General→Editor ==="
STATE=$(digest_state)
expect_state "selected=general"
LAYOUT=$(digest_layout)
read -r nx ny nw nh <<<"$(layout_rect nav_editor "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$nx" "$ny" "$nw" "$nh")"
click_xy "$cx" "$cy"
digest_state >/dev/null
expect_state "selected=editor"
expect_state "focused=nav.editor"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 1 PASS"

# ── Scenario 2: checkbox OFF→ON (launch_at_login) ──
log "[e2e] === scenario 2: checkbox launch_at_login ON ==="
LAYOUT=$(digest_layout)
# back to General first
read -r nx ny nw nh <<<"$(layout_rect nav_general "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$nx" "$ny" "$nw" "$nh")"
click_xy "$cx" "$cy"
digest_state >/dev/null
expect_state "selected=general"
LAYOUT=$(digest_layout)
read -r bx by bw bh <<<"$(layout_rect general_launch_at_login "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$bx" "$by" "$bw" "$bh")"
expect_state "general_launch_at_login=0"
click_xy "$cx" "$cy"
digest_state >/dev/null
expect_state "general_launch_at_login=1"
expect_state "focused=general.launch_at_login"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 2 PASS"

# ── Scenario 3: slider ui_scale drag ──
log "[e2e] === scenario 3: slider ui_scale ==="
STATE=$(digest_state)
SCALE=$(parse_kv general_ui_scale "$STATE")
LAYOUT=$(digest_layout)
read -r sx sy sw sh <<<"$(layout_rect general_ui_scale "$LAYOUT")"
read -r kx ky <<<"$(slider_knob_xy "$sx" "$sy" "$sw" "$sh" "$SCALE" 50 200)"
# drag to near right end of track
RIGHT_X=$((sx + sw - 4))
drive "inject mouse_move $kx $ky; step 1; inject mouse_down left; step 1; inject mouse_move $RIGHT_X $ky; step 2; inject mouse_up left; step 1"
digest_state >/dev/null
expect_state "general_ui_scale>100"
expect_state "focused=general.ui_scale"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 3 PASS"

# ── Scenario 4: section switch + state retention ──
log "[e2e] === scenario 4: section switch state hold ==="
LAYOUT=$(digest_layout)
read -r nx ny nw nh <<<"$(layout_rect nav_editor "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$nx" "$ny" "$nw" "$nh")"
click_xy "$cx" "$cy"
digest_state >/dev/null
expect_state "selected=editor"
LAYOUT=$(digest_layout)
read -r bx by bw bh <<<"$(layout_rect editor_format_on_save "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$bx" "$by" "$bw" "$bh")"
click_xy "$cx" "$cy"
digest_state >/dev/null
expect_state "editor_format_on_save=1"
LAYOUT=$(digest_layout)
read -r nx ny nw nh <<<"$(layout_rect nav_audio "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$nx" "$ny" "$nw" "$nh")"
click_xy "$cx" "$cy"
digest_state >/dev/null
expect_state "selected=audio"
LAYOUT=$(digest_layout)
read -r rx ry rw rh <<<"$(layout_rect audio_output_headphones "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$rx" "$ry" "$rw" "$rh")"
click_xy "$cx" "$cy"
digest_state >/dev/null
expect_state "audio_output=headphones"
LAYOUT=$(digest_layout)
read -r nx ny nw nh <<<"$(layout_rect nav_general "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$nx" "$ny" "$nw" "$nh")"
click_xy "$cx" "$cy"
digest_state >/dev/null
expect_state "selected=general"
expect_state "editor_format_on_save=1"
expect_state "audio_output=headphones"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 4 PASS"

# ── Scenario 5: long form scroll + bottom hit-test + caller 所有 scroll 保持 ──
# ScrollArea の *Vec2f は app 側 state（PerIdStateStore 外）。他 section 表示中も digest 上
# editor_scroll_y が保たれることを固定する（store trim の影響を受けない契約）。
# 再表示直後の 1 フレームは rect_cache miss で max_y=0 clamp し得る（ScrollArea 同期契約・
# TASK-46）。その再 clamp は TASK-127 スコープ外のため、ここでは非表示中の保持のみ assert。
log "[e2e] === scenario 5: editor scroll + workspace_path + scroll ownership ==="
LAYOUT=$(digest_layout)
read -r nx ny nw nh <<<"$(layout_rect nav_editor "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$nx" "$ny" "$nw" "$nh")"
click_xy "$cx" "$cy"
digest_state >/dev/null
expect_state "selected=editor"
LAYOUT=$(digest_layout)
read -r sx sy sw sh <<<"$(layout_rect editor_scroll "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$sx" "$sy" "$sw" "$sh")"
drive "inject mouse_move $cx $cy; step 1; inject scroll 0 -4; step 2"
digest_state >/dev/null
expect_state "editor_scroll_y>0"
STATE=$(digest_state)
SCROLL_Y_BEFORE=$(parse_kv editor_scroll_y "$STATE")
if [[ -z "$SCROLL_Y_BEFORE" ]]; then
  log "[e2e] FAIL: missing editor_scroll_y before section switch"
  exit 1
fi
log "[e2e] editor_scroll_y before switch=$SCROLL_Y_BEFORE"
# Audio へ切替（Editor ScrollArea は非表示）。caller 所有 y が digest に残ること。
LAYOUT=$(digest_layout)
read -r nx ny nw nh <<<"$(layout_rect nav_audio "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$nx" "$ny" "$nw" "$nh")"
click_xy "$cx" "$cy"
digest_state >/dev/null
expect_state "selected=audio"
expect_state "editor_scroll_y=$SCROLL_Y_BEFORE"
log "[e2e] editor_scroll_y held while hidden=$SCROLL_Y_BEFORE"
# Editor へ戻る（既存: workspace_path hit-test）
LAYOUT=$(digest_layout)
read -r nx ny nw nh <<<"$(layout_rect nav_editor "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$nx" "$ny" "$nw" "$nh")"
click_xy "$cx" "$cy"
digest_state >/dev/null
expect_state "selected=editor"
LAYOUT=$(digest_layout)
read -r sx sy sw sh <<<"$(layout_rect editor_scroll "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$sx" "$sy" "$sw" "$sh")"
# 再表示後に cache が戻るまで必要なら再スクロールして workspace_path を露出
drive "inject mouse_move $cx $cy; step 1; inject scroll 0 -4; step 2"
LAYOUT=$(digest_layout)
read -r tx ty tw th <<<"$(layout_rect editor_workspace_path "$LAYOUT")"
# if still -1 or clipped, scroll more
if [[ "$tx" == "-1" ]]; then
  drive "inject mouse_move $cx $cy; step 1; inject scroll 0 -6; step 2"
  LAYOUT=$(digest_layout)
  read -r tx ty tw th <<<"$(layout_rect editor_workspace_path "$LAYOUT")"
fi
read -r cx cy <<<"$(rect_center "$tx" "$ty" "$tw" "$th")"
click_xy "$cx" "$cy"
drive "inject commit /tmp/video-proto-workspace; step 1"
digest_state >/dev/null
expect_state "focused=editor.workspace_path"
expect_state "editor_workspace_path_bytes>0"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 5 PASS"

# ── Scenario 6: radio groups ──
log "[e2e] === scenario 6: audio radio groups ==="
LAYOUT=$(digest_layout)
read -r nx ny nw nh <<<"$(layout_rect nav_audio "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$nx" "$ny" "$nw" "$nh")"
click_xy "$cx" "$cy"
digest_state >/dev/null
expect_state "selected=audio"
LAYOUT=$(digest_layout)
read -r rx ry rw rh <<<"$(layout_rect audio_output_headphones "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$rx" "$ry" "$rw" "$rh")"
click_xy "$cx" "$cy"
digest_state >/dev/null
expect_state "audio_output=headphones"
LAYOUT=$(digest_layout)
read -r rx ry rw rh <<<"$(layout_rect audio_buffer_high "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$rx" "$ry" "$rw" "$rh")"
click_xy "$cx" "$cy"
digest_state >/dev/null
expect_state "audio_buffer_size=high"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 6 PASS"

# ── Scenario 7: textInputId settings_path ──
log "[e2e] === scenario 7: textInput settings_path ==="
LAYOUT=$(digest_layout)
read -r nx ny nw nh <<<"$(layout_rect nav_general "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$nx" "$ny" "$nw" "$nh")"
click_xy "$cx" "$cy"
digest_state >/dev/null
expect_state "selected=general"
LAYOUT=$(digest_layout)
read -r tx ty tw th <<<"$(layout_rect general_settings_path "$LAYOUT")"
read -r cx cy <<<"$(rect_center "$tx" "$ty" "$tw" "$th")"
click_xy "$cx" "$cy"
drive "inject commit /tmp/settings-shell.conf; step 1"
digest_state >/dev/null
expect_state "focused=general.settings_path"
expect_state "general_settings_path_bytes>0"
expect_state "general_settings_path_crc!=00000000"
drive "snapshot fb" >>"$LOG" 2>&1
log "[e2e] scenario 7 PASS"

# clean quit
log "[e2e] quit"
drive "quit" >>"$LOG" 2>&1 || true
sleep 0.2
APP_PID=""
log "[e2e] ALL 7 SCENARIOS PASSED"
log "[e2e] log=$LOG"
exit 0
