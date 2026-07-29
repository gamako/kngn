#!/usr/bin/env bash
# Fill relay must carry the originator's tool: host fill + client eraser, legacy local
# stroke form (no tool=), both peers end at the filled layer (not the receiver eraser no-op).
# Control path: semicolon batches + harness await (same style as the other netsync E2Es).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MAIN="${KNGN_MAIN_DIR:-$ROOT}"
KNGN="$ROOT/scripts/kngn"
PIXIE="$ROOT/zig-out/bin/pixie"
E2E="$ROOT/.e2e/netsync-fill-relay"
NETSYNC_PORT=9410
HOST_PORT="$E2E/host.port"
CLIENT_PORT="$E2E/client.port"
HOST_OUT="$E2E/host-out"
CLIENT_OUT="$E2E/client-out"

cd "$ROOT"
mkdir -p "$E2E" "$HOST_OUT" "$CLIENT_OUT"
rm -f "$HOST_PORT" "$CLIENT_PORT"

log() { printf '%s\n' "$*" >&2; }

# Build once up front and start the peers as plain processes: with a `zig build run-pixie`
# wrapper the recorded pid is the wrapper's, so a peer that ignores quit cannot be reaped
# and keeps the netsync port. Two concurrent `zig build` runs would also contend for the
# build cache.
direnv exec "$MAIN" zig build build-pixie kngn

start_pixie() {
  local port_file=$1 out_dir=$2
  shift 2
  mkdir -p "$out_dir"
  rm -f "$port_file"
  # A fresh application-data directory per peer and per run. Sharing the developer's real
  # one lets a leftover autosave open the modal recovery prompt at startup, and while that
  # prompt is up every injected event goes to it instead of the canvas.
  rm -rf "$out_dir/appdata"
  mkdir -p "$out_dir/appdata"
  # Manual clock: this script drives the frames itself.
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

host_pid=""; client_pid=""
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

wait_join() {
  local budget=2000
  local chunk=10
  local rem=$budget
  local out="" rc=0
  set +e
  out=$(drive_c "await netsync awaiting_sync=0 0" 2>&1)
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    log "join ok"
    return 0
  fi
  while (( rem > 0 )); do
    drive_h "step ${chunk}" >/dev/null
    set +e
    out=$(drive_c "await netsync awaiting_sync=0 ${chunk}" 2>&1)
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      log "join ok"
      return 0
    fi
    rem=$((rem - chunk))
  done
  log "FAIL: join timeout last=$out"
  exit 1
}

# last_seq lower bound: last_seq>(min_seq-1) because await has no >=.
wait_drain() {
  local min_seq=$1
  local bound=$((min_seq - 1))
  local budget=4000
  local chunk=20
  local rem=$budget
  local cout="" hout="" crc=0 hrc=0
  while (( rem > 0 )); do
    drive_h "step ${chunk}" >/dev/null
    set +e
    cout=$(drive_c "step ${chunk}; await netsync pending=0 0; await netsync last_seq>${bound} 0" 2>&1)
    crc=$?
    hout=$(drive_h "await netsync pending=0 0; await netsync last_seq>${bound} 0" 2>&1)
    hrc=$?
    set -e
    if [[ $crc -eq 0 && $hrc -eq 0 ]]; then
      return 0
    fi
    rem=$((rem - chunk))
  done
  log "FAIL: drain timeout min_seq=$min_seq client='$cout' host='$hout'"
  exit 1
}

layer_nz() {
  printf '%s' "$1" | grep -oE 'nz=[0-9]+' | head -1 | cut -d= -f2
}

layer_crc() {
  printf '%s' "$1" | grep -oE 'crc=[0-9A-Fa-f]+' | head -1 | cut -d= -f2
}

log "=== netsync fill relay (originator tool) E2E ==="
host_pid=$(start_pixie "$HOST_PORT" "$HOST_OUT" KNGN_NETSYNC_HOST=1 KNGN_NETSYNC_PORT="$NETSYNC_PORT")
wait_port "$HOST_PORT" "$host_pid"
client_pid=$(start_pixie "$CLIENT_PORT" "$CLIENT_OUT" KNGN_NETSYNC_CONNECT=127.0.0.1:"$NETSYNC_PORT")
wait_port "$CLIENT_PORT" "$client_pid"

wait_join

# Both peers draw a closed square with pen so fill has a region to paint.
# Square is inset (40..80) so seed (10,10) is outside the outline: flood-fill of the
# empty exterior is the established scenario (legacy `action stroke 10 10`).
drive_h 'step 2; action set_tool pen; action set_color FF0000' >/dev/null
drive_c 'step 2; action set_tool pen; action set_color FF0000' >/dev/null
drive_h 'action stroke 40 40 80 40; action stroke 80 40 80 80; action stroke 80 80 40 80; action stroke 40 80 40 40' >/dev/null
wait_drain 4

pre_h=$(drive_h 'digest canvas')
pre_c=$(drive_c 'digest canvas')
pre_h_crc=$(layer_crc "$pre_h")
pre_c_crc=$(layer_crc "$pre_c")
pre_h_nz=$(layer_nz "$pre_h")
pre_c_nz=$(layer_nz "$pre_c")
log "pre-fill host nz=$pre_h_nz crc=$pre_h_crc"
log "pre-fill client nz=$pre_c_nz crc=$pre_c_crc"
if [[ -z "$pre_h_crc" || "$pre_h_crc" != "$pre_c_crc" ]]; then
  log "FAIL: pre-fill layer crc mismatch ($pre_h_crc vs $pre_c_crc)"
  exit 1
fi
if [[ "${pre_h_nz:-0}" -le 0 || "$pre_h_nz" != "$pre_c_nz" ]]; then
  log "FAIL: pre-fill nz missing or mismatch (host=$pre_h_nz client=$pre_c_nz)"
  exit 1
fi

baseline=$(drive_c 'digest netsync')
baseline_seq=$(parse_kv "$baseline" last_seq)
baseline_seq=${baseline_seq:-0}

# Deliberately divergent tools: host fill, client eraser. Assert via tool probe.
drive_h 'action set_tool fill; step 1' >/dev/null
drive_c 'action set_tool eraser; step 1' >/dev/null
host_tool=$(drive_h 'digest tool')
client_tool=$(drive_c 'digest tool')
log "host tool: $host_tool"
log "client tool: $client_tool"
# tool probe prints the display name (Fill / Eraser), not the set_tool token.
if ! printf '%s' "$host_tool" | grep -qiE 'tool=fill\b'; then
  log "FAIL: host tool is not fill: $host_tool"
  exit 1
fi
if ! printf '%s' "$client_tool" | grep -qiE 'tool=eraser\b'; then
  log "FAIL: client tool is not eraser: $client_tool"
  exit 1
fi

# Legacy local form: bare points only. Host canonicalizeStroke must bake fill into the wire action.
# Do not send tool=fill — that would skip the regression this script guards.
drive_h 'action stroke 10 10' >/dev/null
expect_seq=$((baseline_seq + 1))
log "waiting drain after fill expect last_seq>=$expect_seq via last_seq>$((expect_seq - 1))"
wait_drain "$expect_seq"

host_canvas=$(drive_h 'digest canvas')
client_canvas=$(drive_c 'digest canvas')
log "host canvas: $host_canvas"
log "client canvas: $client_canvas"

host_nz=$(layer_nz "$host_canvas")
client_nz=$(layer_nz "$client_canvas")
host_crc=$(layer_crc "$host_canvas")
client_crc=$(layer_crc "$client_canvas")
host_comp=$(parse_kv "$host_canvas" comp)
client_comp=$(parse_kv "$client_canvas" comp)

log "host nz=$host_nz crc=$host_crc comp=$host_comp"
log "client nz=$client_nz crc=$client_crc comp=$client_comp"

# Exterior flood from (10,10) around the inset square paints most of the 256x256 layer
# (typically nz≈64000). Equality alone is not enough: two wrong receivers could agree.
# Require fill-scale nz (far above the outline-only pre-fill) and host/client match.
if [[ "${host_nz:-0}" -lt 10000 ]]; then
  log "FAIL: host nz=$host_nz is not a fill result (expected large non-zero exterior flood)"
  exit 1
fi
if [[ "${client_nz:-0}" -lt 10000 ]]; then
  log "FAIL: client nz=$client_nz is not a fill result (receiver may have applied its own eraser)"
  exit 1
fi
if [[ "$host_nz" != "$client_nz" ]]; then
  log "FAIL: host/client nz mismatch ($host_nz vs $client_nz)"
  exit 1
fi
if [[ "$host_crc" != "$client_crc" ]]; then
  log "FAIL: host/client layer crc mismatch ($host_crc vs $client_crc)"
  exit 1
fi
if [[ "$host_comp" != "$client_comp" ]]; then
  log "FAIL: host/client composite crc mismatch ($host_comp vs $client_comp)"
  exit 1
fi
# Client must have changed from the pre-fill outline (old bug left client at pre-fill nz≈49).
if [[ "$client_nz" == "$pre_c_nz" && "$client_crc" == "$pre_c_crc" ]]; then
  log "FAIL: client canvas unchanged after fill relay (pre nz=$pre_c_nz crc=$pre_c_crc)"
  exit 1
fi

{
  echo "host_nz=$host_nz"
  echo "client_nz=$client_nz"
  echo "crc=$host_crc"
  echo "comp=$host_comp"
  echo "pre_nz=$pre_c_nz"
  echo "host_tool=fill"
  echo "client_tool=eraser"
} >"$E2E/result.txt"

log "PASS: fill relay host/client match nz=$host_nz crc=$host_crc (originator fill, receiver was eraser)"
