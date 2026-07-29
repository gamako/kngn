#!/usr/bin/env bash
# Releasing another stroke before a 300-point stroke's pending clears must not
# drop the first stroke's later chunks.
# Approach: on release, synchronously PROPOSE every chunk → no cross-stroke send-queue discard path.
# Control path: semicolon batches + harness await (no shell sleep/poll drain).
# Intentional freeze: host is not stepped while both strokes are captured.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MAIN="${KNGN_MAIN_DIR:-$ROOT}"
KNGN="$ROOT/scripts/kngn"
PIXIE="$ROOT/zig-out/bin/pixie"
E2E="$ROOT/.e2e/consecutive-stroke"
NETSYNC_PORT=9212
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
  log "FAIL: timeout port $port_file"
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

# Drain both peers to last_seq >= min_seq. last_seq lower bound: last_seq>(min_seq-1).
# Host was intentionally frozen during capture; pumping it here unblocks COMMIT.
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
    cout=$(drive_c "step ${chunk}; await netsync pending=0 0; await netsync last_seq>${bound} 0" 2>&1)
    crc=$?
    hout=$(drive_h "await netsync pending=0 0; await netsync last_seq>${bound} 0" 2>&1)
    hrc=$?
    set -e
    if [[ $crc -eq 0 && $hrc -eq 0 ]]; then
      host_net=$(drive_h 'digest netsync')
      client_net=$(drive_c 'digest netsync')
      hs=$(parse_kv "$host_net" last_seq); hs=${hs:-0}
      cs=$(parse_kv "$client_net" last_seq); cs=${cs:-0}
      log "drain ok host_seq=$hs client_seq=$cs"
      return 0
    fi
    rem=$((rem - chunk))
  done
  log "FAIL: drain timeout min_seq=$min_seq client='$cout' host='$hout'"
  exit 1
}

# Cell coordinates are anchored on VX/VY, the origin of visible_rect: at the startup zoom the
# canvas can be wider than its area, and a press outside the area does not start a stroke
# (the new-stroke gate needs the press inside the canvas area).
# Stroke A takes rows VY+10..VY+15 and stroke B row VY+20, so the two never overlap and the
# non-zero pixel count is the sum of both.
# host_step=0: freeze the host so COMMIT cannot interrupt local capture
# Each point remains inject mouse_move + step 1 (one frame); the whole drag is one ctl batch.
drag_points() {
  local ox=$1 oy=$2 znum=$3 zden=$4 start=$5 end=$6 mode=$7 host_step=$8
  local i cx cy sx sy
  local batch=""
  if [[ "$mode" == "long" ]]; then
    read -r sx sy < <(cell_to_screen "$ox" "$oy" "$znum" "$zden" $((VX + start % 50)) $((VY + 10 + start / 50)))
  else
    read -r sx sy < <(cell_to_screen "$ox" "$oy" "$znum" "$zden" $((VX + start)) $((VY + 20)))
  fi
  batch="inject mouse_move $sx $sy; inject mouse_down left; step 1"
  for i in $(seq "$start" $((end - 1))); do
    if [[ "$mode" == "long" ]]; then
      cx=$((VX + i % 50)); cy=$((VY + 10 + i / 50))
    else
      cx=$((VX + i)); cy=$((VY + 20))
    fi
    read -r sx sy < <(cell_to_screen "$ox" "$oy" "$znum" "$zden" "$cx" "$cy")
    batch+="; inject mouse_move $sx $sy; step 1"
  done
  if [[ "$mode" == "long" ]]; then
    read -r sx sy < <(cell_to_screen "$ox" "$oy" "$znum" "$zden" $((VX + (end - 1) % 50)) $((VY + 10 + (end - 1) / 50)))
  else
    read -r sx sy < <(cell_to_screen "$ox" "$oy" "$znum" "$zden" $((VX + end - 1)) $((VY + 20)))
  fi
  batch+="; inject mouse_move $sx $sy; inject mouse_up left; step 1"
  drive_c "$batch" >/dev/null
  # host_step=0 leaves the host frozen (race under test). host_step=1 is unused by this
  # scenario but kept so a future pump cadence can batch host steps without reopening the race.
  if [[ "$host_step" == "1" ]]; then
    drive_h 'step 1' >/dev/null
  fi
}

log "=== consecutive stroke (pending-clear race) ==="
host_pid=$(start_pixie "$HOST_PORT" "$HOST_OUT" KNGN_NETSYNC_HOST=1 KNGN_NETSYNC_PORT="$NETSYNC_PORT")
wait_port "$HOST_PORT" "$host_pid"
client_pid=$(start_pixie "$CLIENT_PORT" "$CLIENT_OUT" KNGN_NETSYNC_CONNECT=127.0.0.1:"$NETSYNC_PORT")
wait_port "$CLIENT_PORT" "$client_pid"

wait_join

drive_c 'step 2; action set_tool pen; action set_color FF0000' >/dev/null
drive_h 'step 2' >/dev/null
canvas=$(drive_c 'step 1; digest canvas')
ox=$(parse_kv "$canvas" origin_x); oy=$(parse_kv "$canvas" origin_y)
znum=$(parse_kv "$canvas" zoom_num); zden=$(parse_kv "$canvas" zoom_den)
ox=${ox:-0}; oy=${oy:-0}; znum=${znum:-1}; zden=${zden:-1}
vis=$(parse_kv "$canvas" visible_rect)
IFS=, read -r VX VY VW VH <<<"${vis:-0,0,0,0}"
VX=${VX:-0}; VY=${VY:-0}; VW=${VW:-0}; VH=${VH:-0}
log "origin=($ox,$oy) zoom=$znum/$zden visible cells=($VX,$VY)+${VW}x${VH}"
if [[ "$VW" -lt 52 || "$VH" -lt 23 ]]; then
  log "FAIL: visible canvas ${VW}x${VH} cells is too small for the inset stroke grid"
  exit 1
fi
# visible_rect is the flooring of a continuous region, so its first and last cell can be
# partly outside the area; inset by one cell so every injected point maps to a fully
# visible cell.
VX=$((VX + 1)); VY=$((VY + 1))

baseline=$(drive_c 'digest netsync')
baseline_seq=$(parse_kv "$baseline" last_seq); baseline_seq=${baseline_seq:-0}

# The host stays unstepped until both strokes are captured, so its COMMIT for stroke A cannot
# arrive while stroke B is being captured. The final pixel count and crc checks then verify
# that no chunk was lost and that both peers agree.
# The digests below are a trace only: netsync's `pending` is the inbound queue length, not a
# count of the client's proposals awaiting a COMMIT.
log "stroke A: 300 points (host frozen)"
drag_points "$ox" "$oy" "$znum" "$zden" 0 300 long 0
# client-only steps so PROPOSE reaches outbound on the client
drive_c 'step 2' >/dev/null
log "mid after A: $(drive_c 'digest netsync')"

# Stroke B: keep the host frozen → A's COMMIT must not interrupt capture
log "stroke B: 21 points before A is committed"
drag_points "$ox" "$oy" "$znum" "$zden" 0 21 short 0
drive_c 'step 2' >/dev/null
log "mid after B: $(drive_c 'digest netsync')"

expect_seq=$((baseline_seq + 4))
log "waiting full drain expect last_seq>=$expect_seq via last_seq>$((expect_seq - 1))"
hs=0
cs=0
wait_drain "$expect_seq"

host_canvas=$(drive_h 'digest canvas')
client_canvas=$(drive_c 'digest canvas')
host_nz=$(printf '%s' "$host_canvas" | grep -oE 'nz=[0-9]+' | head -1 | cut -d= -f2)
client_nz=$(printf '%s' "$client_canvas" | grep -oE 'nz=[0-9]+' | head -1 | cut -d= -f2)
host_crc=$(printf '%s' "$host_canvas" | grep -oE 'crc=[0-9A-Fa-f]+' | head -1 | cut -d= -f2)
client_crc=$(printf '%s' "$client_canvas" | grep -oE 'crc=[0-9A-Fa-f]+' | head -1 | cut -d= -f2)

log "host nz=$host_nz crc=$host_crc"
log "client nz=$client_nz crc=$client_crc"

# Old bug: nz≈149. Expect: A(300)+B(21) ≈ 321 (non-overlapping)
if [[ "${host_nz:-0}" -lt 300 ]]; then
  log "FAIL: host nz=$host_nz < 300 (stroke A chunks dropped)"
  exit 1
fi
if [[ "${host_nz:-0}" -le 300 ]]; then
  log "FAIL: host nz=$host_nz — stroke B missing (expected >300, ~321)"
  exit 1
fi
if [[ "$host_nz" != "$client_nz" || "$host_crc" != "$client_crc" ]]; then
  log "FAIL: host/client mismatch nz/crc"
  exit 1
fi

{
  echo "nz=$host_nz"
  echo "crc=$host_crc"
  echo "host_seq=$hs"
} >"$E2E/result.txt"

log "PASS: consecutive strokes preserved nz=$host_nz (A+B, no chunk drop)"
