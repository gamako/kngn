#!/usr/bin/env bash
# Releasing another stroke before a 300-point stroke's pending clears must not
# drop the first stroke's later chunks.
# Approach: on release, synchronously PROPOSE every chunk → no cross-stroke send-queue discard path.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MAIN="${KNGN_MAIN_DIR:-$ROOT}"
DRIVE="$ROOT/scripts/drive"
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

start_pixie() {
  local port_file=$1 out_dir=$2
  shift 2
  mkdir -p "$out_dir"
  rm -f "$port_file"
  env KNGN_HARNESS_PORT_FILE="$port_file" KNGN_HARNESS_OUT="$out_dir" "$@" \
    direnv exec "$MAIN" zig build run-pixie >"$out_dir/app.log" 2>&1 &
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
  "$DRIVE" --port-file "$port_file" 'quit' >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  log "WARN: pid $pid still alive after quit"
}

host_pid=""; client_pid=""
cleanup() {
  quit_pid "$HOST_PORT" "${host_pid:-}" 2>/dev/null || true
  quit_pid "$CLIENT_PORT" "${client_pid:-}" 2>/dev/null || true
}
trap cleanup EXIT

drive_h() { "$DRIVE" --port-file "$HOST_PORT" "$1"; }
drive_c() { "$DRIVE" --port-file "$CLIENT_PORT" "$1"; }

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

# host_step=0: freeze the host so COMMIT cannot interrupt local capture
drag_points() {
  local ox=$1 oy=$2 znum=$3 zden=$4 start=$5 end=$6 mode=$7 host_step=$8
  local i cx cy sx sy
  if [[ "$mode" == "long" ]]; then
    read -r sx sy < <(cell_to_screen "$ox" "$oy" "$znum" "$zden" $((start % 50)) $((10 + start / 50)))
  else
    read -r sx sy < <(cell_to_screen "$ox" "$oy" "$znum" "$zden" "$start" 100)
  fi
  drive_c "inject mouse_move $sx $sy; inject mouse_down left; step 1" >/dev/null
  if [[ "$host_step" == "1" ]]; then drive_h 'step 1' >/dev/null; fi
  for i in $(seq "$start" $((end - 1))); do
    if [[ "$mode" == "long" ]]; then
      cx=$((i % 50)); cy=$((10 + i / 50))
    else
      cx=$i; cy=100
    fi
    read -r sx sy < <(cell_to_screen "$ox" "$oy" "$znum" "$zden" "$cx" "$cy")
    drive_c "inject mouse_move $sx $sy; step 1" >/dev/null
    if [[ "$host_step" == "1" ]] && (( i % 10 == 0 )); then drive_h 'step 1' >/dev/null; fi
  done
  if [[ "$mode" == "long" ]]; then
    read -r sx sy < <(cell_to_screen "$ox" "$oy" "$znum" "$zden" $(((end - 1) % 50)) $((10 + (end - 1) / 50)))
  else
    read -r sx sy < <(cell_to_screen "$ox" "$oy" "$znum" "$zden" $((end - 1)) 100)
  fi
  drive_c "inject mouse_move $sx $sy; inject mouse_up left; step 1" >/dev/null
}

log "=== consecutive stroke (pending-clear race) ==="
host_pid=$(start_pixie "$HOST_PORT" "$HOST_OUT" KNGN_NETSYNC_HOST=1 KNGN_NETSYNC_PORT="$NETSYNC_PORT")
wait_port "$HOST_PORT" "$host_pid"
client_pid=$(start_pixie "$CLIENT_PORT" "$CLIENT_OUT" KNGN_NETSYNC_CONNECT=127.0.0.1:"$NETSYNC_PORT")
wait_port "$CLIENT_PORT" "$client_pid"

for i in $(seq 1 2000); do
  drive_h 'step 1' >/dev/null 2>&1 || true
  out=$(drive_c 'step 1; digest netsync' 2>/dev/null || true)
  printf '%s' "$out" | grep -q 'awaiting_sync=0' && break
  sleep 0.05
done

drive_c 'step 2; action set_tool pen; action set_color FF0000' >/dev/null
drive_h 'step 2' >/dev/null
canvas=$(drive_c 'step 1; digest canvas' 2>/dev/null || true)
ox=$(parse_kv "$canvas" origin_x); oy=$(parse_kv "$canvas" origin_y)
znum=$(parse_kv "$canvas" zoom_num); zden=$(parse_kv "$canvas" zoom_den)
ox=${ox:-0}; oy=${oy:-0}; znum=${znum:-1}; zden=${zden:-1}
log "origin=($ox,$oy) zoom=$znum/$zden"

baseline=$(drive_c 'digest netsync' 2>/dev/null || true)
baseline_seq=$(parse_kv "$baseline" last_seq); baseline_seq=${baseline_seq:-0}

# Stroke A: barely advance the host (leave pending after release)
log "stroke A: 300 points (host mostly frozen)"
drag_points "$ox" "$oy" "$znum" "$zden" 0 300 long 0
# client-only steps so PROPOSE reaches outbound on the client
drive_c 'step 2' >/dev/null
mid=$(drive_c 'digest netsync' 2>/dev/null || true)
log "mid after A: $mid"
mp=$(parse_kv "$mid" pending); mp=${mp:-0}
if [[ "$mp" -lt 3 ]]; then
  # Even if the host advances accidentally, expect at least Stroke A's PROPOSE trace
  log "WARN: pending after A is $mp (expected ~3 if host frozen)"
fi

# Stroke B: keep the host frozen → A's COMMIT must not interrupt capture
log "stroke B: 21 points while A still pending"
drag_points "$ox" "$oy" "$znum" "$zden" 0 21 short 0
drive_c 'step 2' >/dev/null
mid2=$(drive_c 'digest netsync' 2>/dev/null || true)
log "mid after B: $mid2"
mp2=$(parse_kv "$mid2" pending); mp2=${mp2:-0}
if [[ "$mp2" -lt 4 ]]; then
  log "WARN: pending after B is $mp2 (expected >=4 if both proposed)"
fi

expect_seq=$((baseline_seq + 4))
log "waiting full drain expect last_seq>=$expect_seq"
ok=0
for i in $(seq 1 8000); do
  drive_h 'step 1' >/dev/null 2>&1 || true
  drive_c 'step 1' >/dev/null 2>&1 || true
  ho=$(drive_h 'digest netsync' 2>/dev/null || true)
  co=$(drive_c 'digest netsync' 2>/dev/null || true)
  hs=$(parse_kv "$ho" last_seq); hs=${hs:-0}
  cs=$(parse_kv "$co" last_seq); cs=${cs:-0}
  hp=$(parse_kv "$ho" pending); hp=${hp:-9}
  cp=$(parse_kv "$co" pending); cp=${cp:-9}
  if [[ "$hp" == "0" && "$cp" == "0" && "$hs" -ge "$expect_seq" && "$cs" -ge "$expect_seq" ]]; then
    ok=1
    log "drain ok host_seq=$hs client_seq=$cs"
    break
  fi
  sleep 0.05
done
if [[ "$ok" != "1" ]]; then
  log "FAIL: drain timeout host='$ho' client='$co'"
  exit 1
fi

host_canvas=$(drive_h 'digest canvas' 2>/dev/null || true)
client_canvas=$(drive_c 'digest canvas' 2>/dev/null || true)
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
