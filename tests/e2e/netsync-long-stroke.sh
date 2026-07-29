#!/usr/bin/env bash
# A 300-point UI drag over netsync relay must not vanish (host/client crc match, nz>0).
# When direnv is broken in a workspace, borrow the main flake via KNGN_MAIN_DIR.
# Control path: semicolon batches + harness await (no shell sleep/poll drain).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MAIN="${KNGN_MAIN_DIR:-$ROOT}"
KNGN="$ROOT/scripts/kngn"
PIXIE="$ROOT/zig-out/bin/pixie"
E2E="$ROOT/.e2e/netsync-long-stroke"
NETSYNC_PORT=9210
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
  # Manual clock: this script drives the frames itself (one injected point per frame, and it
  # freezes a peer by not stepping it), which free-run LISTEN cannot express.
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
  # Last resort: kill this pid only. A survivor keeps holding the netsync port and
  # poisons the next run.
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

# canvas cell → screen (digest origin/zoom_num, zoom_den)
cell_to_screen() {
  local ox=$1 oy=$2 num=$3 den=$4 cx=$5 cy=$6
  if [[ "$den" == "1" ]]; then
    echo $((ox + cx * num)) $((oy + cy * num))
  else
    local half=$(( (den - 1) / 2 ))
    echo $((ox + (cx - half) / den)) $((oy + (cy - half) / den))
  fi
}

# Manual-clock peers only advance while their harness connection is stepped.
# Stage a bounded host pump, then await on the client (which drives client frames).
# Small chunks avoid burning full frame budgets when the condition is almost ready.
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

# Drain both peers to last_seq >= min_seq with pending clear and no reject.
# last_seq lower bound uses strict > (await has no >=): last_seq>(min_seq-1).
# Alternating bounded step batches (no shell sleep); await timeout 0 is the ready check.
wait_drain() {
  local min_seq=$1
  local bound=$((min_seq - 1))
  local budget=8000
  local chunk=20
  local rem=$budget
  local cout="" hout="" crc=0 hrc=0
  while (( rem > 0 )); do
    drive_h "step ${chunk}" >/dev/null
    set +e
    cout=$(drive_c "step ${chunk}; await netsync awaiting_sync=0 0; await netsync pending=0 0; await netsync last_seq>${bound} 0; await netsync last_reject=none 0" 2>&1)
    crc=$?
    hout=$(drive_h "await netsync awaiting_sync=0 0; await netsync pending=0 0; await netsync last_seq>${bound} 0; await netsync last_reject=none 0" 2>&1)
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

log "=== netsync 300-point stroke E2E ==="
host_pid=$(start_pixie "$HOST_PORT" "$HOST_OUT" KNGN_NETSYNC_HOST=1 KNGN_NETSYNC_PORT="$NETSYNC_PORT")
wait_port "$HOST_PORT" "$host_pid"
client_pid=$(start_pixie "$CLIENT_PORT" "$CLIENT_OUT" KNGN_NETSYNC_CONNECT=127.0.0.1:"$NETSYNC_PORT")
wait_port "$CLIENT_PORT" "$client_pid"

wait_join
drive_c 'step 3; action set_tool pen; action set_color FF0000' >/dev/null
drive_h 'step 3' >/dev/null
wait_join

baseline=$(drive_c 'digest netsync')
baseline_seq=$(parse_kv "$baseline" last_seq)
baseline_seq=${baseline_seq:-0}
log "baseline last_seq=$baseline_seq"

canvas=$(drive_c 'step 1; digest canvas')
ox=$(parse_kv "$canvas" origin_x)
oy=$(parse_kv "$canvas" origin_y)
znum=$(parse_kv "$canvas" zoom_num)
zden=$(parse_kv "$canvas" zoom_den)
ox=${ox:-0}; oy=${oy:-0}; znum=${znum:-1}; zden=${zden:-1}
log "canvas origin=($ox,$oy) zoom=$znum/$zden"

# The grid is anchored on visible_rect: at the startup zoom the canvas can be wider than its
# area, and a press outside the area does not start a stroke (the new-stroke gate needs the
# press inside the canvas area), so cell 0 is not necessarily reachable.
# visible_rect is the flooring of a continuous region, so its first and last cell can be
# partly outside the area; inset by one cell and keep one cell of margin at the far edge, so
# every injected point maps to a fully visible cell.
vis=$(parse_kv "$canvas" visible_rect)
IFS=, read -r vx vy vw vh <<<"${vis:-0,0,0,0}"
vx=${vx:-0}; vy=${vy:-0}; vw=${vw:-0}; vh=${vh:-0}
log "visible cells=($vx,$vy)+${vw}x${vh}"
if [[ "$vw" -lt 52 || "$vh" -lt 18 ]]; then
  log "FAIL: visible canvas ${vw}x${vh} cells is too small for an inset 50x6 grid"
  exit 1
fi
vx=$((vx + 1)); vy=$((vy + 1))

# 300 distinct canvas points: (vx + i%50, vy + 10 + i/50) for i=0..299
# Important: canvas_input reads mouse_pos once per frame, so each point is
# `inject mouse_move + step 1` (one frame each; consecutive moves in one step keep only the last coord).
# One semicolon batch keeps one control connection for the whole drag.
read -r sx0 sy0 < <(cell_to_screen "$ox" "$oy" "$znum" "$zden" "$vx" $((vy + 10)))
batch="inject mouse_move $sx0 $sy0; inject mouse_down left; step 1"
local_i=0
for local_i in $(seq 0 299); do
  cx=$((vx + local_i % 50))
  cy=$((vy + 10 + local_i / 50))
  read -r sx sy < <(cell_to_screen "$ox" "$oy" "$znum" "$zden" "$cx" "$cy")
  batch+="; inject mouse_move $sx $sy; step 1"
done
read -r sx sy < <(cell_to_screen "$ox" "$oy" "$znum" "$zden" $((vx + 299 % 50)) $((vy + 10 + 299 / 50)))
batch+="; inject mouse_move $sx $sy; inject mouse_up left; step 1"
drive_c "$batch" >/dev/null
# Host was frozen during the client drag; pump it so accept/COMMIT can start, then drain.
drive_h 'step 20' >/dev/null

expect_seq=$((baseline_seq + 3))
log "waiting netsync drain (expect last_seq>=$expect_seq via last_seq>$((expect_seq - 1)), pending=0)..."
wait_drain "$expect_seq"

# Final digests after pending has cleared
host_net=$(drive_h 'digest netsync')
client_net=$(drive_c 'digest netsync')
hs=$(parse_kv "$host_net" last_seq); hs=${hs:-0}
cs=$(parse_kv "$client_net" last_seq); cs=${cs:-0}
log "drain sequences host_seq=$hs client_seq=$cs"

host_canvas=$(drive_h 'digest canvas')
client_canvas=$(drive_c 'digest canvas')
log "host canvas: $host_canvas"
log "client canvas: $client_canvas"

host_nz=$(printf '%s' "$host_canvas" | grep -oE 'nz=[0-9]+' | head -1 | cut -d= -f2)
client_nz=$(printf '%s' "$client_canvas" | grep -oE 'nz=[0-9]+' | head -1 | cut -d= -f2)
host_crc=$(printf '%s' "$host_canvas" | grep -oE 'crc=[0-9A-Fa-f]+' | head -1 | cut -d= -f2)
client_crc=$(printf '%s' "$client_canvas" | grep -oE 'crc=[0-9A-Fa-f]+' | head -1 | cut -d= -f2)
host_comp=$(parse_kv "$host_canvas" comp)
client_comp=$(parse_kv "$client_canvas" comp)

log "host nz=$host_nz crc=$host_crc comp=$host_comp"
log "client nz=$client_nz crc=$client_crc comp=$client_comp"

if [[ "${host_nz:-0}" -le 0 ]]; then
  log "FAIL: host layer nz<=0 (stroke disappeared)"
  exit 1
fi
if [[ "${client_nz:-0}" -le 0 ]]; then
  log "FAIL: client layer nz<=0 (stroke disappeared)"
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

{
  echo "nz=$host_nz"
  echo "crc=$host_crc"
  echo "comp=$host_comp"
  echo "host_seq=$hs"
  echo "client_seq=$cs"
  echo "baseline_seq=$baseline_seq"
} >"$E2E/result.txt"

log "PASS: 300-point stroke nz=$host_nz crc=$host_crc host/client match"
