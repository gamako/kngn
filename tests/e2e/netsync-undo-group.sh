#!/usr/bin/env bash
# An operation sent as several relayed actions must undo, and redo, as one unit on every peer.
# The host brackets two strokes with `group begin` / `group end`; one undo has to take both back
# on the host and on the client, and one redo has to bring both back.
# When direnv is broken in a workspace, borrow the main flake via KNGN_MAIN_DIR.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MAIN="${KNGN_MAIN_DIR:-$ROOT}"
KNGN="$ROOT/scripts/kngn"
PIXIE="$ROOT/zig-out/bin/pixie"
E2E="$ROOT/.e2e/netsync-undo-group"
NETSYNC_PORT=9300
HOST_PORT="$E2E/host.port"
CLIENT_PORT="$E2E/client.port"
HOST_OUT="$E2E/host-out"
CLIENT_OUT="$E2E/client-out"

cd "$ROOT"
mkdir -p "$E2E" "$HOST_OUT" "$CLIENT_OUT"
rm -f "$HOST_PORT" "$CLIENT_PORT"

log() { printf '%s\n' "$*" >&2; }

direnv exec "$MAIN" zig build build-pixie kngn

start_pixie() {
  local port_file=$1 out_dir=$2
  shift 2
  mkdir -p "$out_dir"
  rm -f "$port_file"
  rm -rf "$out_dir/appdata"
  mkdir -p "$out_dir/appdata"
  env KNGN_APPSHELL_DIR="$out_dir/appdata" KNGN_HEADLESS=1 KNGN_HARNESS_LISTEN= \
    KNGN_HARNESS_MANUAL_CLOCK=1 KNGN_HARNESS_PORT_FILE="$port_file" \
    KNGN_HARNESS_OUT="$out_dir" "$@" "$PIXIE" >"$out_dir/app.log" 2>&1 &
  echo $!
}

wait_port() {
  local port_file=$1 pid=$2
  local i
  for i in $(seq 1 2000); do
    kill -0 "$pid" 2>/dev/null || { log "FAIL: process $pid died before port $port_file"; exit 1; }
    [[ -f "$port_file" ]] && return 0
    sleep 0.05
  done
  log "FAIL: timeout waiting for port file $port_file"
  exit 1
}

quit_pid() {
  local port_file=$1 pid=$2
  "$KNGN" ctl --port-file "$port_file" 'quit' >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  log "WARN: pid $pid still alive after quit"
  kill -KILL "$pid" 2>/dev/null || true
}

cleanup() {
  quit_pid "$HOST_PORT" "${host_pid:-}" 2>/dev/null || true
  quit_pid "$CLIENT_PORT" "${client_pid:-}" 2>/dev/null || true
}
trap cleanup EXIT

drive_h() { "$KNGN" ctl --port-file "$HOST_PORT" "$1"; }
drive_c() { "$KNGN" ctl --port-file "$CLIENT_PORT" "$1"; }

parse_kv() {
  local text=$1 key=$2
  printf '%s' "$text" | grep -oE "${key}=[^ ]+" | head -1 | cut -d= -f2-
}

layer_crc() {
  printf '%s' "$1" | grep -oE 'crc=[0-9A-Fa-f]+' | head -1 | cut -d= -f2
}

wait_join() {
  local rem=2000 chunk=10 rc=0 out=""
  set +e
  out=$(drive_c "await netsync awaiting_sync=0 0" 2>&1); rc=$?
  set -e
  [[ $rc -eq 0 ]] && { log "join ok"; return 0; }
  while (( rem > 0 )); do
    drive_h "step ${chunk}" >/dev/null
    set +e
    out=$(drive_c "await netsync awaiting_sync=0 ${chunk}" 2>&1); rc=$?
    set -e
    [[ $rc -eq 0 ]] && { log "join ok"; return 0; }
    rem=$((rem - chunk))
  done
  log "FAIL: join timeout last=$out"
  exit 1
}

# Drain both peers to last_seq >= min_seq with pending clear and no reject.
wait_drain() {
  local min_seq=$1
  local bound=$((min_seq - 1))
  local rem=8000 chunk=20 cout="" hout="" crc=0 hrc=0
  while (( rem > 0 )); do
    drive_h "step ${chunk}" >/dev/null
    set +e
    cout=$(drive_c "step ${chunk}; await netsync awaiting_sync=0 0; await netsync pending=0 0; await netsync last_seq>${bound} 0; await netsync last_reject=none 0" 2>&1)
    crc=$?
    hout=$(drive_h "await netsync pending=0 0; await netsync last_seq>${bound} 0; await netsync last_reject=none 0" 2>&1)
    hrc=$?
    set -e
    if [[ $crc -eq 0 && $hrc -eq 0 ]]; then
      log "drain ok min_seq=$min_seq"
      return 0
    fi
    rem=$((rem - chunk))
  done
  log "FAIL: netsync drain timeout min_seq=$min_seq client='$cout' host='$hout'"
  exit 1
}

log "=== netsync undo-group E2E ==="
host_pid=$(start_pixie "$HOST_PORT" "$HOST_OUT" KNGN_NETSYNC_HOST=1 KNGN_NETSYNC_PORT="$NETSYNC_PORT")
wait_port "$HOST_PORT" "$host_pid"
client_pid=$(start_pixie "$CLIENT_PORT" "$CLIENT_OUT" KNGN_NETSYNC_CONNECT=127.0.0.1:"$NETSYNC_PORT")
wait_port "$CLIENT_PORT" "$client_pid"

wait_join
drive_h 'step 3; action set_tool pen; action set_color FF0000' >/dev/null
drive_c 'step 3' >/dev/null
wait_join

base_h=$(layer_crc "$(drive_h 'step 1; digest canvas')")
base_c=$(layer_crc "$(drive_c 'step 1; digest canvas')")
log "baseline host=$base_h client=$base_c"
if [[ "$base_h" != "$base_c" ]]; then
  log "FAIL: baseline crc already differs ($base_h vs $base_c)"
  exit 1
fi

# One logical operation, sent as two relayed actions inside one undo group.
drive_h 'group begin; action stroke 10 10 60 10; action stroke 10 20 60 20; group end' >/dev/null
wait_drain 2

drawn_h=$(layer_crc "$(drive_h 'digest canvas')")
drawn_c=$(layer_crc "$(drive_c 'digest canvas')")
log "after group host=$drawn_h client=$drawn_c"
if [[ "$drawn_h" != "$drawn_c" ]]; then
  log "FAIL: host/client crc mismatch after the group ($drawn_h vs $drawn_c)"
  exit 1
fi
if [[ "$drawn_h" == "$base_h" ]]; then
  log "FAIL: the grouped strokes changed nothing"
  exit 1
fi

# ONE undo must take BOTH members back, on both peers.
drive_h 'action undo' >/dev/null
wait_drain 4

undone_h=$(layer_crc "$(drive_h 'digest canvas')")
undone_c=$(layer_crc "$(drive_c 'digest canvas')")
log "after one undo host=$undone_h client=$undone_c (baseline $base_h)"
if [[ "$undone_h" != "$base_h" ]]; then
  log "FAIL: one undo did not take the whole group back on the host ($undone_h != $base_h)"
  exit 1
fi
if [[ "$undone_c" != "$base_h" ]]; then
  log "FAIL: one undo did not take the whole group back on the client ($undone_c != $base_h)"
  exit 1
fi

# ONE redo must bring BOTH back.
drive_h 'action redo' >/dev/null
wait_drain 6

redone_h=$(layer_crc "$(drive_h 'digest canvas')")
redone_c=$(layer_crc "$(drive_c 'digest canvas')")
log "after one redo host=$redone_h client=$redone_c (drawn $drawn_h)"
if [[ "$redone_h" != "$drawn_h" ]]; then
  log "FAIL: one redo did not bring the whole group back on the host ($redone_h != $drawn_h)"
  exit 1
fi
if [[ "$redone_c" != "$drawn_h" ]]; then
  log "FAIL: one redo did not bring the whole group back on the client ($redone_c != $drawn_h)"
  exit 1
fi

host_hist=$(drive_h 'digest netsync')
client_hist=$(drive_c 'digest netsync')
log "host  netsync: $host_hist"
log "client netsync: $client_hist"

{
  echo "baseline_crc=$base_h"
  echo "grouped_crc=$drawn_h"
  echo "undone_crc=$undone_h"
  echo "redone_crc=$redone_h"
} >"$E2E/result.txt"

log "PASS: two relayed actions form one undo unit (undo $drawn_h -> $undone_h, redo -> $redone_h) on host and client"
