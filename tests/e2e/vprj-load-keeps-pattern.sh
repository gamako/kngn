#!/usr/bin/env bash
# VPRJ load must not wipe a saved pattern via seed reset (solo bit-identical + netsync SYNC).
# When direnv is required, set KNGN_MAIN_DIR to the video-proto-main path (borrow the flake outside the workspace).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MAIN="${KNGN_MAIN_DIR:-$ROOT}"
DRIVE="$ROOT/scripts/drive"
cd "$ROOT"
WORKDIR=$(mktemp -d /tmp/t151-XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

PATTERN_EXPECT='"kick":"1981".*"hat":"1050".*"clap":"c444".*"bass_on":"4949"'
PATTERN_ACTIONS='action set_evolve 0; action seed 42; action pattern kick x ~ ~ ~ ~ ~ ~ x x ~ ~ x x ~ ~ ~; action pattern hat ~ ~ ~ ~ x ~ x ~ ~ ~ ~ ~ x ~ ~ ~; action pattern clap ~ ~ x ~ ~ ~ x ~ ~ ~ x ~ ~ ~ x x; action pattern bass 0 ~ ~ 0 ~ ~ 0 ~ 0 ~ ~ 0 ~ ~ 0 ~'

log() { printf '%s\n' "$*" >&2; }

start_patch() {
  local port_file=$1 out_dir=$2
  shift 2
  mkdir -p "$out_dir"
  rm -f "$port_file"
  # extra args are NAME=value env assignments (e.g. KNGN_NETSYNC_HOST=1)
  env KNGN_HEADLESS=1 KNGN_HARNESS_LISTEN= KNGN_HARNESS_PORT_FILE="$port_file" KNGN_HARNESS_OUT="$out_dir" "$@" \
    direnv exec "$MAIN" zig build run-patch >"$out_dir/app.log" 2>&1 &
  echo $!
}

wait_port() {
  local port_file=$1 pid=$2
  local i
  for i in $(seq 1 2000); do
    kill -0 "$pid" 2>/dev/null || { log "FAIL: process $pid died before port $port_file"; tail -20 "$WORKDIR"/*/app.log 2>/dev/null || true; exit 1; }
    if [[ -f "$port_file" ]]; then
      return 0
    fi
    sleep 0.05
  done
  log "FAIL: timeout waiting for port file $port_file"
  exit 1
}

wait_masks() {
  local port_file=$1 pid=$2
  local i out
  for i in $(seq 1 2000); do
    kill -0 "$pid" 2>/dev/null || { log "FAIL: process $pid died while waiting masks"; exit 1; }
    out=$("$DRIVE" --port-file "$port_file" 'step 1; digest modular' 2>/dev/null || true)
    if printf '%s\n' "$out" | grep -qE "$PATTERN_EXPECT"; then
      printf '%s\n' "$out"
      return 0
    fi
    sleep 0.05
  done
  log "FAIL: timeout waiting for pattern masks on $port_file"
  log "last digest: ${out:-<empty>}"
  exit 1
}

quit_pid() {
  local port_file=$1 pid=$2
  "$DRIVE" --port-file "$port_file" 'quit' >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  kill -KILL "$pid" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# solo: save → load → cross a bar → save → cmp bit-identical
# ---------------------------------------------------------------------------
log "=== solo E2E ==="
SOLO_PORT=/tmp/t151-solo.port
SOLO_OUT="$WORKDIR/solo-out"
BEFORE="$WORKDIR/before.vprj"
AFTER="$WORKDIR/after.vprj"

solo_pid=$(start_patch "$SOLO_PORT" "$SOLO_OUT")
wait_port "$SOLO_PORT" "$solo_pid"
"$DRIVE" --port-file "$SOLO_PORT" "$PATTERN_ACTIONS"

before_digest=$(wait_masks "$SOLO_PORT" "$solo_pid")
log "solo before masks: $(printf '%s' "$before_digest" | grep -oE '"patterns":\{[^}]+\}')"
"$DRIVE" --port-file "$SOLO_PORT" "snapshot fb $WORKDIR/solo-restored.png"
"$DRIVE" --port-file "$SOLO_PORT" "action save_project $BEFORE"
"$DRIVE" --port-file "$SOLO_PORT" 'action toggle_step kick 1'
"$DRIVE" --port-file "$SOLO_PORT" 'step 1'
"$DRIVE" --port-file "$SOLO_PORT" "action load_project $BEFORE"

after_load_digest=$(wait_masks "$SOLO_PORT" "$solo_pid")
log "solo after load masks: $(printf '%s' "$after_load_digest" | grep -oE '"patterns":\{[^}]+\}')"
"$DRIVE" --port-file "$SOLO_PORT" "action save_project $AFTER"

if ! cmp -s "$BEFORE" "$AFTER"; then
  log "FAIL: VPRJ bit mismatch after save→load→save"
  ls -la "$BEFORE" "$AFTER"
  exit 1
fi
log "solo PASS: cmp bit-identical before/after"

quit_pid "$SOLO_PORT" "$solo_pid"
rm -f "$SOLO_PORT"

# ---------------------------------------------------------------------------
# netsync: host-edited pattern → client SYNC → digest modular match
# ---------------------------------------------------------------------------
log "=== netsync E2E ==="
HOST_PORT=/tmp/t151-host.port
CLIENT_PORT=/tmp/t151-client.port
HOST_OUT="$WORKDIR/host-out"
CLIENT_OUT="$WORKDIR/client-out"

host_pid=$(start_patch "$HOST_PORT" "$HOST_OUT" KNGN_NETSYNC_HOST=1 KNGN_NETSYNC_PORT=9150)
wait_port "$HOST_PORT" "$host_pid"
"$DRIVE" --port-file "$HOST_PORT" "$PATTERN_ACTIONS"
host_pre=$(wait_masks "$HOST_PORT" "$host_pid")
log "host pre-join masks: $(printf '%s' "$host_pre" | grep -oE '"patterns":\{[^}]+\}')"

client_pid=$(start_patch "$CLIENT_PORT" "$CLIENT_OUT" KNGN_NETSYNC_CONNECT=127.0.0.1:9150)
wait_port "$CLIENT_PORT" "$client_pid"

synced=0
for i in $(seq 1 2000); do
  kill -0 "$host_pid" 2>/dev/null || { log "FAIL: host died during SYNC wait"; exit 1; }
  kill -0 "$client_pid" 2>/dev/null || { log "FAIL: client died during SYNC wait"; exit 1; }
  "$DRIVE" --port-file "$HOST_PORT" 'step 1' >/dev/null || true
  net=$("$DRIVE" --port-file "$CLIENT_PORT" 'step 1; digest netsync' 2>/dev/null || true)
  if printf '%s\n' "$net" | grep -q 'awaiting_sync=0'; then
    synced=1
    break
  fi
  sleep 0.05
done
if [[ "$synced" -ne 1 ]]; then
  log "FAIL: timeout waiting for client awaiting_sync=0"
  exit 1
fi

client_ok=0
client_out=""
for i in $(seq 1 2000); do
  kill -0 "$host_pid" 2>/dev/null || { log "FAIL: host died during pattern wait"; exit 1; }
  kill -0 "$client_pid" 2>/dev/null || { log "FAIL: client died during pattern wait"; exit 1; }
  "$DRIVE" --port-file "$HOST_PORT" 'step 1' >/dev/null || true
  client_out=$("$DRIVE" --port-file "$CLIENT_PORT" 'step 1; digest modular' 2>/dev/null || true)
  if printf '%s\n' "$client_out" | grep -qE "$PATTERN_EXPECT"; then
    client_ok=1
    break
  fi
  sleep 0.05
done
if [[ "$client_ok" -ne 1 ]]; then
  log "FAIL: timeout waiting for client pattern masks"
  log "last client digest: ${client_out:-<empty>}"
  exit 1
fi

host_digest=$("$DRIVE" --port-file "$HOST_PORT" 'digest modular')
client_digest=$("$DRIVE" --port-file "$CLIENT_PORT" 'digest modular')
log "host digest patterns: $(printf '%s' "$host_digest" | grep -oE '"patterns":\{[^}]+\}')"
log "client digest patterns: $(printf '%s' "$client_digest" | grep -oE '"patterns":\{[^}]+\}')"

printf '%s\n' "$host_digest" | grep -qE "$PATTERN_EXPECT" || { log "FAIL: host masks mismatch"; exit 1; }
printf '%s\n' "$client_digest" | grep -qE "$PATTERN_EXPECT" || { log "FAIL: client masks mismatch"; exit 1; }

quit_pid "$HOST_PORT" "$host_pid"
quit_pid "$CLIENT_PORT" "$client_pid"
rm -f "$HOST_PORT" "$CLIENT_PORT"

log "netsync PASS: host/client pattern masks match"
log "ALL VPRJ load pattern E2E PASSED"
log "solo_before_patterns=$(printf '%s' "$before_digest" | grep -oE '"patterns":\{[^}]+\}')"
log "solo_after_load_patterns=$(printf '%s' "$after_load_digest" | grep -oE '"patterns":\{[^}]+\}')"
log "netsync_host_patterns=$(printf '%s' "$host_digest" | grep -oE '"patterns":\{[^}]+\}')"
log "netsync_client_patterns=$(printf '%s' "$client_digest" | grep -oE '"patterns":\{[^}]+\}')"
