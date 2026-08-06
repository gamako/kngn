#!/usr/bin/env bash
# Headless Chrome e2e: mic_demo wasm capture with fake mic WAV + COOP/COEP.
#
# Asserts (via [mic_demo] lines posted to /__e2e_log when URL has ?e2e=1):
#   - permission granted
#   - capture started
#   - captureMismatches stays 0
#   - no permission denied / connect failed
#
# Chrome: /Applications/Google Chrome.app/... (override with $CHROME).
# Restricted agent/CI sandboxes need --no-sandbox (documented below).
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
WAV="$E2E/fake-mic-440hz.wav"
# Chrome process stderr (noisy). App e2e events go to APP_LOG via /__e2e_log.
CHROME_LOG="${MIC_CAPTURE_CHROME_LOG:-/tmp/mic-capture-headless.chrome.log}"
APP_LOG="${MIC_CAPTURE_LOG:-/tmp/mic-capture-headless.log}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
PORT="${MIC_CAPTURE_PORT:-8765}"
RUN_SECS="${MIC_CAPTURE_SECS:-15}"

log() { printf '%s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kngn-mic-capture-e2e-XXXXXX")
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR" "$WORK/chrome-profile"

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

log "==> generate fake mic WAV"
python3 "$E2E/gen_fake_mic_wav.py" "$WAV"
[[ -f "$WAV" ]] || fail "WAV not generated: $WAV"

log "==> package-web (mic_demo + COOP/COEP assets)"
direnv exec "$MAIN" zig build package-web

WEB="$ROOT/zig-out/web"
[[ -f "$WEB/mic-demo.html" ]] || fail "missing $WEB/mic-demo.html"
[[ -f "$WEB/mic_demo.wasm" ]] || fail "missing $WEB/mic_demo.wasm"
[[ -f "$WEB/kngn.js" ]] || fail "missing $WEB/kngn.js"
[[ -f "$WEB/kngn-worklet.js" ]] || fail "missing $WEB/kngn-worklet.js"

log "==> serve COOP/COEP + e2e log sink on 127.0.0.1:$PORT"
: >"$APP_LOG"
python3 "$E2E/serve_mic_e2e.py" "$WEB" "$PORT" "$APP_LOG" >"$WORK/server.log" 2>&1 &
server_pid=$!

for _ in $(seq 1 50); do
  if curl -sf -o /dev/null "http://127.0.0.1:$PORT/mic-demo.html"; then
    break
  fi
  sleep 0.1
done
curl -sf -o /dev/null "http://127.0.0.1:$PORT/mic-demo.html" \
  || fail "server did not become ready (see $WORK/server.log)"

HEADERS=$(curl -sI "http://127.0.0.1:$PORT/mic-demo.html")
echo "$HEADERS" | grep -qi 'cross-origin-opener-policy: same-origin' \
  || fail "missing COOP header"
echo "$HEADERS" | grep -qi 'cross-origin-embedder-policy: require-corp' \
  || fail "missing COEP header"

URL="http://127.0.0.1:$PORT/mic-demo.html?e2e=1"
log "==> headless Chrome via CDP ($RUN_SECS s) $URL"
: >"$CHROME_LOG"
# CDP driver opens about:blank then Page.navigate (raw Chrome+URL often never loads
# under restricted sandboxes). --no-sandbox / --use-gl=disabled inside the driver.
set +e
python3 "$E2E/chrome_cdp_run.py" \
  --chrome "$CHROME" \
  --url "$URL" \
  --wav "$WAV" \
  --user-data-dir="$WORK/chrome-profile" \
  --seconds "$RUN_SECS" \
  --console-log "$CHROME_LOG"
cdp_ec=$?
set -e
if [[ "$cdp_ec" -ne 0 ]]; then
  log "cdp_run exit=$cdp_ec"
fi

# Merge CDP console capture + POST /__e2e_log sink for asserts.
COMBINED="$WORK/combined.log"
{
  cat "$APP_LOG" 2>/dev/null || true
  cat "$CHROME_LOG" 2>/dev/null || true
} >"$COMBINED"

log "==> assert combined log ($COMBINED)"
if [[ ! -s "$COMBINED" ]]; then
  log "--- server log ---"
  cat "$WORK/server.log" >&2 || true
  fail "empty combined log (CDP console empty and no /__e2e_log POSTs — page never ran)"
fi

log "--- combined e2e log ---"
cat "$COMBINED" >&2 || true

grep -q '\[mic_demo\] permission granted' "$COMBINED" \
  || fail "missing permission granted (getUserMedia / fake mic flags)"

grep -q '\[mic_demo\] capture started' "$COMBINED" \
  || fail "missing capture started (open/start or AudioContext resume)"

grep -q '\[mic_demo\] capture stats' "$COMBINED" \
  || fail "missing capture stats (worklet poll-stats inactive?)"

LAST_MISMATCH=$(
  grep '\[mic_demo\] capture stats' "$COMBINED" \
    | tail -1 \
    | sed -n 's/.*captureMismatches=\([0-9][0-9]*\).*/\1/p'
)
[[ -n "$LAST_MISMATCH" ]] || fail "could not parse captureMismatches"
if [[ "$LAST_MISMATCH" -gt 0 ]]; then
  fail "captureMismatches=$LAST_MISMATCH (expected 0)"
fi

if grep -qiE 'permission denied|capture connect failed' "$COMBINED"; then
  fail "capture error/denied found in log"
fi

log "PASS: mic_demo headless capture e2e (permission granted, source connected, mismatches=0)"
exit 0
