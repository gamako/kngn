#!/usr/bin/env bash
# Verify automatic app-data isolation for unattended harness runs,
# display-backed live keeps real app-data, and blocked-injection warnings.
#
# Style: batch with `;`, wait with `await` (no outer sleep-polling loops for digests).
# Ports are ephemeral and port files live under $WORK so parallel runs do not collide.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MAIN="${KNGN_MAIN_DIR:-$ROOT}"
KNGN="$ROOT/scripts/kngn"
PIXIE="$ROOT/zig-out/bin/pixie"

log() { printf '%s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kngn-appdata-isolation-XXXXXX")
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"

# Per-case port files under $WORK (never a fixed name under /tmp).
PORT_FILE=""
pixie_pid=""
seed_pid=""

# quit (if port_file given) → wait for exit → KILL if needed → wait. Never uses pkill.
stop_pid() {
  local pid=${1:-}
  local port_file=${2:-}
  [[ -n "$pid" ]] || return 0
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    return 0
  fi
  if [[ -n "$port_file" && -f "$port_file" ]]; then
    "$KNGN" ctl --port-file "$port_file" 'quit' >/dev/null 2>&1 || true
  fi
  local i
  for i in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "$pid" 2>/dev/null; then
    log "WARN: pid $pid still alive after quit; sending KILL"
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  stop_pid "${pixie_pid:-}" "${PORT_FILE:-}"
  pixie_pid=""
  stop_pid "${seed_pid:-}"
  seed_pid=""
  # Leave $WORK for diagnosis; /tmp reclaims it.
}
trap 'cleanup' EXIT

cd "$ROOT"
direnv exec "$MAIN" zig build build-pixie kngn

test -x "$PIXIE"
test -x "$ROOT/zig-out/bin/kngn" || test -x "$KNGN"

FAKE_HOME="$WORK/home"
APPSHELL_SEED="$WORK/seed-appdata"
OUT="$WORK/out"
mkdir -p "$FAKE_HOME" "$APPSHELL_SEED" "$OUT"

# Resolve the conventional app-data path under the fake home and assert it stays inside $WORK
# before any write (never touch the developer's real Application Support / XDG config).
case "$(uname -s)" in
  Darwin)
    REAL_APPDATA="$FAKE_HOME/Library/Application Support/pixie"
    ;;
  Linux)
    export XDG_CONFIG_HOME="$WORK/xdg-config"
    mkdir -p "$XDG_CONFIG_HOME"
    REAL_APPDATA="$XDG_CONFIG_HOME/pixie"
    ;;
  *)
    fail "unsupported OS $(uname -s)"
    ;;
esac

case "$REAL_APPDATA" in
  "$WORK"/*) ;;
  *) fail "resolved app-data path escapes fixture: $REAL_APPDATA" ;;
esac
log "fixture app-data (under WORK): $REAL_APPDATA"
log "TMPDIR (isolation root parent): $TMPDIR"

# --- Seed an autosave via explicit KNGN_APPSHELL_DIR (isolation does not apply) ---
seed_script="$OUT/seed.txt"
printf '%s\n' 'step 3; action stroke 30 30 80 80; digest canvas; step 1000000000' >"$seed_script"
mkdir -p "$OUT/seed"
env HOME="$FAKE_HOME" KNGN_APPSHELL_DIR="$APPSHELL_SEED" KNGN_HEADLESS=1 \
  KNGN_HARNESS_SCRIPT="$seed_script" KNGN_HARNESS_OUT="$OUT/seed" \
  "$PIXIE" >"$OUT/seed/app.log" 2>&1 &
seed_pid=$!
autosave_file=
for _ in $(seq 1 200); do
  autosave_file=$(find "$APPSHELL_SEED/autosave" -type f -name '*.autosave' -print -quit 2>/dev/null || true)
  [[ -n "$autosave_file" ]] && break
  kill -0 "$seed_pid" 2>/dev/null || fail "seed process died before autosave"
  sleep 0.05
done
[[ -n "$autosave_file" ]] || fail "autosave not created under $APPSHELL_SEED"
stop_pid "$seed_pid"
seed_pid=""
log "seeded autosave: $autosave_file"

# Place the same autosave under the conventional fake-home path.
mkdir -p "$REAL_APPDATA/autosave"
cp "$autosave_file" "$REAL_APPDATA/autosave/"
[[ -f "$REAL_APPDATA/autosave/$(basename "$autosave_file")" ]] || fail "copy into fake app-data failed"

ctl() {
  "$KNGN" ctl --port-file "$PORT_FILE" "$1"
}

wait_port() {
  local pid=$1
  local port_file=$2
  local i
  for i in $(seq 1 2000); do
    kill -0 "$pid" 2>/dev/null || fail "process $pid died before port $port_file"
    [[ -f "$port_file" ]] && return 0
    sleep 0.05
  done
  fail "timeout waiting for $port_file"
}

start_live() {
  local out_dir=$1
  shift
  PORT_FILE="$out_dir/harness.port"
  rm -f "$PORT_FILE"
  mkdir -p "$out_dir"
  # Empty LISTEN = ephemeral port; port file is under $out_dir (inside $WORK).
  env HOME="$FAKE_HOME" KNGN_HARNESS_LISTEN= \
    KNGN_HARNESS_MANUAL_CLOCK=1 KNGN_HARNESS_PORT_FILE="$PORT_FILE" \
    KNGN_HARNESS_OUT="$out_dir" "$@" \
    "$PIXIE" >"$out_dir/app.log" 2>&1 &
  pixie_pid=$!
  wait_port "$pixie_pid" "$PORT_FILE"
}

stop_live() {
  stop_pid "$pixie_pid" "$PORT_FILE"
  pixie_pid=""
  PORT_FILE=""
}

parse_stats_key() {
  # Extract a JSON number field from a digests stats line (… "key":N …).
  local text=$1 key=$2
  printf '%s' "$text" | grep -oE "\"${key}\":[0-9]+" | head -1 | cut -d: -f2
}

# ============================================================================
# 1) Replay isolation: SCRIPT present → temp app-data → modal=none despite fake-home autosave
# ============================================================================
log "=== 1) replay isolation ==="
replay_script="$OUT/replay-isolate.txt"
printf '%s\n' \
  'step 2; await appshell modal=none 120; expect appshell recovery=none; expect appshell modal=none; snapshot fb; quit' \
  >"$replay_script"
mkdir -p "$OUT/replay"
env HOME="$FAKE_HOME" KNGN_HEADLESS=1 \
  KNGN_HARNESS_SCRIPT="$replay_script" KNGN_HARNESS_OUT="$OUT/replay" \
  "$PIXIE" >"$OUT/replay/app.log" 2>&1
# Fake-home autosave must still be present (replay did not open / consume it).
find "$REAL_APPDATA/autosave" -name '*.autosave' -print -quit | grep -q . \
  || fail "fake-home autosave disappeared during isolated replay"
grep -q 'modal=none' "$OUT/replay/app.log" || fail "replay did not report modal=none"
# Isolated writes must stay under $WORK (via TMPDIR).
if find "$TMPDIR" -type d -name 'kngn-appdata-*' -print -quit 2>/dev/null | grep -q .; then
  log "isolated app-data under TMPDIR (expected)"
fi
log "PASS: replay isolation (modal=none, fake-home autosave intact)"

# ============================================================================
# 2a) Headless live isolation: HEADLESS=1 → isolate → modal=none
# ============================================================================
log "=== 2a) headless live isolation ==="
start_live "$OUT/live-headless" KNGN_HEADLESS=1
ctl 'step 2; await appshell modal=none 120; expect appshell recovery=none; expect appshell modal=none' >/dev/null
ctl 'quit' >/dev/null
stop_live
log "PASS: headless live isolation (modal=none)"

# ============================================================================
# 2b) Display live keeps real app-data: LISTEN + HEADLESS unset → modal=recovery
# ============================================================================
log "=== 2b) display live uses real (fake-home) app-data ==="
# No KNGN_HEADLESS: isolation must NOT apply. Requires a display session.
start_live "$OUT/live-display"
ctl 'step 2; await appshell modal=recovery 180; expect appshell recovery=pending; expect appshell modal=recovery' >/dev/null
ctl 'action discard_recovery; await appshell modal=none 120; quit' >/dev/null
stop_live
log "PASS: display live sees recovery modal (not isolated)"

# Case 3 uses $APPSHELL_SEED (untouched by display-live). Ensure the autosave is still there.
[[ -f "$autosave_file" ]] || fail "seed autosave missing before case 3: $autosave_file"

# ============================================================================
# 3) Explicit KNGN_APPSHELL_DIR + inject → blocked warning + modal_blocked_injections += 1
# ============================================================================
log "=== 3) blocked injection counter ==="
start_live "$OUT/blocked" KNGN_APPSHELL_DIR="$APPSHELL_SEED" KNGN_HEADLESS=1
ctl 'step 2; await appshell modal=recovery 180' >/dev/null
before=$(ctl 'digest stats')
before_n=$(parse_stats_key "$before" modal_blocked_injections)
before_n=${before_n:-0}
# One inject while the recovery modal is up; counter must rise by exactly 1.
after=$(ctl 'inject mouse_move 40 40; step 1; digest stats')
after_n=$(parse_stats_key "$after" modal_blocked_injections)
after_n=${after_n:-0}
delta=$((after_n - before_n))
[[ "$delta" -eq 1 ]] || fail "modal_blocked_injections delta=$delta (before=$before_n after=$after_n); response=$after"
# Same label stretch: a second inject increments again but must not fail the process.
after2=$(ctl 'inject mouse_move 41 41; step 1; digest stats')
after2_n=$(parse_stats_key "$after2" modal_blocked_injections)
after2_n=${after2_n:-0}
[[ "$after2_n" -eq $((after_n + 1)) ]] || fail "second inject counter=$after2_n expected $((after_n + 1))"
# Warning must appear in the live response or app log (does not affect exit code).
if ! printf '%s' "$after" | grep -q 'warning: an injected event was consumed by "recovery"'; then
  grep -q 'warning: an injected event was consumed by "recovery"' "$OUT/blocked/app.log" \
    || fail "blocked-injection warning not observed"
fi
ctl 'action discard_recovery; quit' >/dev/null
stop_live
log "PASS: modal_blocked_injections +1 and warning observed"

log "PASS: all app-data isolation checks"
