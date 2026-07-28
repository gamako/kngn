#!/usr/bin/env bash
# A 300-point UI drag over netsync relay must not vanish (host/client crc match, nz>0).
# When direnv is broken in a workspace, borrow the main flake via KNGN_MAIN_DIR.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MAIN="${KNGN_MAIN_DIR:-$ROOT}"
KNGN="$ROOT/scripts/kngn"
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
    kill -0 "$pid" 2>/dev/null || { log "FAIL: process $pid died before port $port_file"; tail -40 "$E2E"/*/app.log 2>/dev/null || true; exit 1; }
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
  # last resort (should not reach): leave for trap note — no pkill
  log "WARN: pid $pid still alive after quit"
}

cleanup() {
  quit_pid "$HOST_PORT" "${host_pid:-}" 2>/dev/null || true
  quit_pid "$CLIENT_PORT" "${client_pid:-}" 2>/dev/null || true
}
trap cleanup EXIT

drive_h() { "$KNGN" ctl --port-file "$HOST_PORT" "$1"; }
drive_c() { "$KNGN" ctl --port-file "$CLIENT_PORT" "$1"; }

# Alternate host+client steps while waiting on the condition
wait_until() {
  local who=$1 # host|client|both
  local pattern=$2
  local i out=""
  for i in $(seq 1 4000); do
    drive_h 'step 1' >/dev/null 2>&1 || true
    drive_c 'step 1' >/dev/null 2>&1 || true
    case "$who" in
      host) out=$(drive_h 'digest netsync' 2>/dev/null || true) ;;
      client) out=$(drive_c 'digest netsync' 2>/dev/null || true) ;;
      both)
        local ho co
        ho=$(drive_h 'digest netsync' 2>/dev/null || true)
        co=$(drive_c 'digest netsync' 2>/dev/null || true)
        if printf '%s\n' "$ho" | grep -qE "$pattern" && printf '%s\n' "$co" | grep -qE "$pattern"; then
          printf '%s\n' "$ho"
          return 0
        fi
        sleep 0.05
        continue
        ;;
    esac
    if printf '%s\n' "$out" | grep -qE "$pattern"; then
      printf '%s\n' "$out"
      return 0
    fi
    sleep 0.05
  done
  log "FAIL: timeout waiting pattern=$pattern who=$who last=$out"
  exit 1
}

parse_kv() {
  # parse_kv TEXT KEY → value after key=
  local text=$1 key=$2
  printf '%s' "$text" | grep -oE "${key}=[^ ]+" | head -1 | cut -d= -f2-
}

# canvas cell → screen (digest origin/zoom_num, zoom_den)
cell_to_screen() {
  local ox=$1 oy=$2 num=$3 den=$4 cx=$5 cy=$6
  if [[ "$den" == "1" ]]; then
    echo $((ox + cx * num)) $((oy + cy * num))
  else
    # shrink: inverse of dx*den+half ≈ cx → dx = (cx - half) / den
    local half=$(( (den - 1) / 2 ))
    echo $((ox + (cx - half) / den)) $((oy + (cy - half) / den))
  fi
}

log "=== netsync 300-point stroke E2E ==="
host_pid=$(start_pixie "$HOST_PORT" "$HOST_OUT" KNGN_NETSYNC_HOST=1 KNGN_NETSYNC_PORT="$NETSYNC_PORT")
wait_port "$HOST_PORT" "$host_pid"
client_pid=$(start_pixie "$CLIENT_PORT" "$CLIENT_OUT" KNGN_NETSYNC_CONNECT=127.0.0.1:"$NETSYNC_PORT")
wait_port "$CLIENT_PORT" "$client_pid"

wait_until client 'awaiting_sync=0' >/dev/null
log "join ok"

# layout + baseline
drive_c 'step 3; action set_tool pen; action set_color FF0000' >/dev/null
drive_h 'step 3' >/dev/null
wait_until both 'awaiting_sync=0' >/dev/null

baseline=$(drive_c 'digest netsync' 2>/dev/null || true)
baseline_seq=$(parse_kv "$baseline" last_seq)
baseline_seq=${baseline_seq:-0}
log "baseline last_seq=$baseline_seq"

canvas=$(drive_c 'step 1; digest canvas' 2>/dev/null || true)
ox=$(parse_kv "$canvas" origin_x)
oy=$(parse_kv "$canvas" origin_y)
znum=$(parse_kv "$canvas" zoom_num)
zden=$(parse_kv "$canvas" zoom_den)
ox=${ox:-0}; oy=${oy:-0}; znum=${znum:-1}; zden=${zden:-1}
log "canvas origin=($ox,$oy) zoom=$znum/$zden"

# 300 distinct canvas points: (i%50, 10+i/50) for i=0..299
# Important: canvas_input reads mouse_pos once per frame, so
# each point is `inject mouse_move + step 1` (one frame each; consecutive moves in one step keep only the last coord).
read -r sx0 sy0 < <(cell_to_screen "$ox" "$oy" "$znum" "$zden" 0 10)
drive_c "inject mouse_move $sx0 $sy0; inject mouse_down left; step 1" >/dev/null
drive_h 'step 1' >/dev/null

for i in $(seq 0 299); do
  cx=$((i % 50))
  cy=$((10 + i / 50))
  read -r sx sy < <(cell_to_screen "$ox" "$oy" "$znum" "$zden" "$cx" "$cy")
  drive_c "inject mouse_move $sx $sy; step 1" >/dev/null
  # Also pump the host regularly (accept/COMMIT)
  if (( i % 5 == 0 )); then
    drive_h 'step 1' >/dev/null
  fi
done

read -r sx sy < <(cell_to_screen "$ox" "$oy" "$znum" "$zden" $((299 % 50)) $((10 + 299 / 50)))
drive_c "inject mouse_move $sx $sy; inject mouse_up left; step 1" >/dev/null
drive_h 'step 1' >/dev/null

# Wait first for pending clear + last_seq advance (expect chunk count >= 3)
expect_seq=$((baseline_seq + 3))
log "waiting netsync drain (expect last_seq>=$expect_seq, pending=0)..."
local_ok=0
for i in $(seq 1 8000); do
  drive_h 'step 1' >/dev/null 2>&1 || true
  drive_c 'step 1' >/dev/null 2>&1 || true
  ho=$(drive_h 'digest netsync' 2>/dev/null || true)
  co=$(drive_c 'digest netsync' 2>/dev/null || true)
  hs=$(parse_kv "$ho" last_seq); hs=${hs:-0}
  cs=$(parse_kv "$co" last_seq); cs=${cs:-0}
  hp=$(parse_kv "$ho" pending); hp=${hp:-9}
  cp=$(parse_kv "$co" pending); cp=${cp:-9}
  ha=$(parse_kv "$ho" awaiting_sync); ha=${ha:-1}
  ca=$(parse_kv "$co" awaiting_sync); ca=${ca:-1}
  hr=$(parse_kv "$ho" last_reject); hr=${hr:-x}
  cr=$(parse_kv "$co" last_reject); cr=${cr:-x}
  if [[ "$ha" == "0" && "$ca" == "0" && "$hp" == "0" && "$cp" == "0" \
        && "$hs" -ge "$expect_seq" && "$cs" -ge "$expect_seq" \
        && "$hr" == "none" && "$cr" == "none" ]]; then
    local_ok=1
    log "drain ok host_seq=$hs client_seq=$cs"
    break
  fi
  sleep 0.05
done
if [[ "$local_ok" != "1" ]]; then
  log "FAIL: netsync drain timeout host='$ho' client='$co'"
  exit 1
fi

# Only then judge the canvas, after pending has cleared
host_canvas=$(drive_h 'digest canvas' 2>/dev/null || true)
client_canvas=$(drive_c 'digest canvas' 2>/dev/null || true)
log "host canvas: $host_canvas"
log "client canvas: $client_canvas"

# layer0 nested: id=... crc=... nz=...
extract_l0() {
  printf '%s' "$1" | grep -oE 'id=[0-9]+ name=[^ ]+ .*nz=[0-9]+' | head -1
}
# Prefer first layer's crc/nz from digest (format: ... {id=N ... crc=XXXXXXXX nz=N} ...)
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

# record for parent summary
{
  echo "nz=$host_nz"
  echo "crc=$host_crc"
  echo "comp=$host_comp"
  echo "host_seq=$hs"
  echo "client_seq=$cs"
  echo "baseline_seq=$baseline_seq"
} >"$E2E/result.txt"

log "PASS: 300-point stroke nz=$host_nz crc=$host_crc host/client match"
