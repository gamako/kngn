#!/usr/bin/env bash
# Headless Chrome e2e: digest frameprof on a wasm-harness mic_demo package.
#
# Builds one -Dwasm-harness=true bundle, copies it to two package roots, and
# measures capture=0 then capture=1 through the host bridge. Port 8767.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
if [[ -n "${KNGN_MAIN_DIR:-}" ]]; then
  MAIN="$KNGN_MAIN_DIR"
elif [[ -f "$ROOT/../../kngn/.envrc" ]]; then
  MAIN=$(cd "$ROOT/../../kngn" && pwd)
else
  MAIN="$ROOT"
fi
E2E="$ROOT/tests/e2e"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
PORT="${WASM_FRAMEPROF_PORT:-8767}"

log() { printf '%s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kngn-wasm-frameprof-e2e-XXXXXX")
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR" "$WORK/pkg/before" "$WORK/pkg/after" \
  "$WORK/chrome-before" "$WORK/chrome-after"

WAV="$WORK/fake-mic.wav"
APP_LOG="$WORK/app.log"
SERVER_LOG="$WORK/server.log"
CMDS="$WORK/commands.txt"
BEFORE_CONSOLE="$WORK/before.console.log"
AFTER_CONSOLE="$WORK/after.console.log"
BEFORE_RESP="$WORK/before.digest.txt"
AFTER_RESP="$WORK/after.digest.txt"

server_pid=""
chrome_pid=""

cleanup() {
  if [[ -n "${chrome_pid:-}" ]] && kill -0 "$chrome_pid" 2>/dev/null; then
    kill "$chrome_pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 "$chrome_pid" 2>/dev/null || break
      sleep 0.2
    done
    if kill -0 "$chrome_pid" 2>/dev/null; then
      kill -9 "$chrome_pid" 2>/dev/null || true
    fi
    wait "$chrome_pid" 2>/dev/null || true
  fi
  chrome_pid=""
  if [[ -n "${server_pid:-}" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  server_pid=""
}
trap 'cleanup' EXIT

cd "$ROOT"

[[ -x "$CHROME" ]] || fail "Chrome not found at: $CHROME"

cat >"$CMDS" <<'EOF'
action frameprof_reset
step 180
digest frameprof
EOF

extract_field() {
  python3 -c '
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
key = sys.argv[2]
line = ""
for raw in text.splitlines():
    if raw.startswith("frameprof ") and "frames=" in raw:
        line = raw
if not line:
    sys.exit(1)
m = re.search(r"(?:^| )" + re.escape(key) + r"=([0-9.]+)", line)
if not m:
    sys.exit(1)
print(m.group(1))
' "$1" "$2"
}

# Bytes already in the shared /__e2e_log sink. Each case slices only what it appends.
app_log_size() {
  if [[ -f "$APP_LOG" ]]; then
    wc -c <"$APP_LOG" | tr -d '[:space:]'
  else
    printf '0'
  fi
}

# Combine this case's /__e2e_log slice with its CDP console. Never read earlier cases.
build_case_log() {
  local start_bytes="$1"
  local console_log="$2"
  local dest="$3"
  python3 -c '
import sys
app_path, start, console_path, dest = sys.argv[1:5]
start = int(start)
chunks = []
try:
    with open(app_path, "rb") as f:
        f.seek(start)
        chunks.append(f.read())
except FileNotFoundError:
    pass
try:
    with open(console_path, "rb") as f:
        chunks.append(f.read())
except FileNotFoundError:
    pass
with open(dest, "wb") as f:
    f.write(b"".join(chunks))
' "$APP_LOG" "$start_bytes" "$console_log" "$dest"
}

assert_capture_off() {
  local name="$1"
  local case_log="$2"
  log "==> assert $name capture off ($case_log)"
  log "--- $name case log ---"
  cat "$case_log" >&2 || true
  if grep -q '\[mic_demo\] capture started' "$case_log"; then
    fail "$name: capture started in $case_log (expected capture off)"
  fi
  if grep -q '\[mic_demo\] permission granted' "$case_log"; then
    fail "$name: permission granted in $case_log (expected capture off)"
  fi
  if grep -q '\[mic_demo\] capture stats' "$case_log"; then
    fail "$name: capture stats in $case_log (expected capture off)"
  fi
}

assert_capture_on() {
  local name="$1"
  local case_log="$2"
  log "==> assert $name capture on ($case_log)"
  if [[ ! -s "$case_log" ]]; then
    log "--- server log ---"
    cat "$SERVER_LOG" >&2 || true
    fail "$name: empty case log $case_log"
  fi
  log "--- $name case log ---"
  cat "$case_log" >&2 || true
  grep -q '\[mic_demo\] permission granted' "$case_log" \
    || fail "$name: missing permission granted in $case_log"
  grep -q '\[mic_demo\] capture started' "$case_log" \
    || fail "$name: missing capture started in $case_log"
  grep -q '\[mic_demo\] capture stats' "$case_log" \
    || fail "$name: missing capture stats in $case_log"
  local last_mismatch
  last_mismatch=$(
    grep '\[mic_demo\] capture stats' "$case_log" \
      | tail -1 \
      | sed -n 's/.*captureMismatches=\([0-9][0-9]*\).*/\1/p'
  )
  [[ -n "$last_mismatch" ]] || fail "$name: could not parse captureMismatches in $case_log"
  if [[ "$last_mismatch" -gt 0 ]]; then
    fail "$name: captureMismatches=$last_mismatch in $case_log (expected 0)"
  fi
  if grep -qiE 'permission denied|capture connect failed' "$case_log"; then
    fail "$name: capture error/denied in $case_log"
  fi
}

log "==> generate fake mic WAV"
python3 "$E2E/gen_fake_mic_wav.py" "$WAV"
[[ -f "$WAV" ]] || fail "WAV not generated: $WAV"

log "==> package-web -Dwasm-harness=true"
direnv exec "$MAIN" zig build package-web -Dwasm-harness=true

WEB="$ROOT/zig-out/web"
[[ -f "$WEB/mic-demo.html" ]] || fail "missing $WEB/mic-demo.html"
[[ -f "$WEB/mic_demo.wasm" ]] || fail "missing $WEB/mic_demo.wasm"
[[ -f "$WEB/kngn.js" ]] || fail "missing $WEB/kngn.js"
[[ -f "$WEB/kngn-worklet.js" ]] || fail "missing $WEB/kngn-worklet.js"

cp -R "$WEB"/. "$WORK/pkg/before/"
cp -R "$WEB"/. "$WORK/pkg/after/"

log "==> serve COOP/COEP + e2e log sink on 127.0.0.1:$PORT"
: >"$APP_LOG"
python3 "$E2E/serve_mic_e2e.py" "$WORK/pkg" "$PORT" "$APP_LOG" >"$SERVER_LOG" 2>&1 &
server_pid=$!

ready=0
for _ in $(seq 1 50); do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    fail "server died before becoming ready (see $SERVER_LOG)"
  fi
  if curl -sf -o /dev/null "http://127.0.0.1:$PORT/before/mic-demo.html"; then
    ready=1
    break
  fi
  sleep 0.1
done
[[ "$ready" -eq 1 ]] || fail "server did not become ready (see $SERVER_LOG)"
if ! kill -0 "$server_pid" 2>/dev/null; then
  fail "server died after readiness (see $SERVER_LOG)"
fi

HEADERS=$(curl -sI "http://127.0.0.1:$PORT/before/mic-demo.html")
echo "$HEADERS" | grep -qi 'cross-origin-opener-policy: same-origin' \
  || fail "missing COOP header"
echo "$HEADERS" | grep -qi 'cross-origin-embedder-policy: require-corp' \
  || fail "missing COEP header"

run_case() {
  local name="$1"
  local path="$2"
  local capture="$3"
  local profile="$4"
  local console_log="$5"
  local resp="$6"
  local secs="$7"
  local case_url="http://127.0.0.1:$PORT/${path}/mic-demo.html?capture=${capture}&e2e=1"

  if ! kill -0 "$server_pid" 2>/dev/null; then
    fail "server died before $name"
  fi

  log "==> $name capture=$capture $case_url"
  local app_off
  app_off=$(app_log_size)
  : >"$console_log"
  set +e
  python3 "$E2E/chrome_cdp_run.py" \
    --chrome "$CHROME" \
    --url "$case_url" \
    --wav "$WAV" \
    --user-data-dir="$profile" \
    --seconds "$secs" \
    --console-log "$console_log" \
    --harness-commands "$CMDS" \
    --harness-response "$resp"
  local cdp_ec=$?
  set -e
  if [[ "$cdp_ec" -ne 0 ]]; then
    log "--- $name console ---"
    cat "$console_log" >&2 || true
    log "--- server log ---"
    cat "$SERVER_LOG" >&2 || true
    fail "$name: chrome_cdp_run exit=$cdp_ec"
  fi
  [[ -s "$resp" ]] || fail "$name: empty host-bridge response"

  log "--- $name host-bridge response ---"
  cat "$resp" >&2 || true

  local frames body gap frame
  frames=$(extract_field "$resp" frames) || fail "$name: missing frames"
  body=$(extract_field "$resp" body_ms) || fail "$name: missing body_ms"
  gap=$(extract_field "$resp" gap_ms) || fail "$name: missing gap_ms"
  frame=$(extract_field "$resp" frame_ms) || fail "$name: missing frame_ms"

  python3 -c 'import sys; n=float(sys.argv[1]); sys.exit(0 if n>0 else 1)' "$frames" \
    || fail "$name: frames=$frames (expected > 0)"
  python3 -c '
import sys
f, b, g = map(float, sys.argv[1:])
if abs((b + g) - f) > 0.005:
    sys.exit(1)
' "$frame" "$body" "$gap" \
    || fail "$name: frame_ms=$frame is not body_ms+gap_ms ($body+$gap)"

  printf '%s\n' "$frames" >"$WORK/${name}.frames"
  printf '%s\n' "$body" >"$WORK/${name}.body_ms"
  printf '%s\n' "$gap" >"$WORK/${name}.gap_ms"
  printf '%s\n' "$frame" >"$WORK/${name}.frame_ms"

  local case_log="$WORK/${name}.combined.log"
  build_case_log "$app_off" "$console_log" "$case_log"
  if [[ "$capture" == "0" ]]; then
    assert_capture_off "$name" "$case_log"
  else
    assert_capture_on "$name" "$case_log"
  fi
}

run_case before before 0 "$WORK/chrome-before" "$BEFORE_CONSOLE" "$BEFORE_RESP" 8
run_case after after 1 "$WORK/chrome-after" "$AFTER_CONSOLE" "$AFTER_RESP" 8

log "==> before (capture=0)  frames=$(cat "$WORK/before.frames") body_ms=$(cat "$WORK/before.body_ms") gap_ms=$(cat "$WORK/before.gap_ms") frame_ms=$(cat "$WORK/before.frame_ms")"
log "==> after  (capture=1)  frames=$(cat "$WORK/after.frames") body_ms=$(cat "$WORK/after.body_ms") gap_ms=$(cat "$WORK/after.gap_ms") frame_ms=$(cat "$WORK/after.frame_ms")"
log "PASS: wasm frameprof headless e2e (before capture off, after capture mismatches=0)"
exit 0
