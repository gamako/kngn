#!/usr/bin/env bash
# History thumbnails during netsync (self/peer both thumb=true, bbox!=null) + solo regression.
# Control path: semicolon batches + harness await (no shell sleep/poll drain).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MAIN="${KNGN_MAIN_DIR:-$ROOT}"
KNGN="$ROOT/scripts/kngn"
PIXIE="$ROOT/zig-out/bin/pixie"
E2E="$ROOT/.e2e/netsync-history-thumb"
NETSYNC_PORT=9211
HOST_PORT="$E2E/host.port"
CLIENT_PORT="$E2E/client.port"
HOST_OUT="$E2E/host-out"
CLIENT_OUT="$E2E/client-out"
SOLO_PORT="$E2E/solo.port"
SOLO_OUT="$E2E/solo-out"

cd "$ROOT"
mkdir -p "$E2E" "$HOST_OUT" "$CLIENT_OUT" "$SOLO_OUT"
rm -f "$HOST_PORT" "$CLIENT_PORT" "$SOLO_PORT"

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
    kill -0 "$pid" 2>/dev/null || { log "FAIL: process $pid died before $port_file"; exit 1; }
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

host_pid=""; client_pid=""; solo_pid=""
cleanup() {
  quit_pid "$HOST_PORT" "${host_pid:-}" 2>/dev/null || true
  quit_pid "$CLIENT_PORT" "${client_pid:-}" 2>/dev/null || true
  quit_pid "$SOLO_PORT" "${solo_pid:-}" 2>/dev/null || true
}
trap cleanup EXIT

drive_h() { "$KNGN" ctl --port-file "$HOST_PORT" "$1"; }
drive_c() { "$KNGN" ctl --port-file "$CLIENT_PORT" "$1"; }
drive_s() { "$KNGN" ctl --port-file "$SOLO_PORT" "$1"; }

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

# Drain both peers to last_seq >= min_seq. last_seq lower bound: last_seq>(min_seq-1).
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

# Assert history JSON has stroke with actor_peer=P, thumb=true, bbox not null
assert_stroke_thumb() {
  local json=$1 peer=$2 label=$3
  # Fixed key order in appendEntryJson: ... actor_peer, kind, name, ... thumb, bbox
  local hit
  hit=$(printf '%s' "$json" | grep -oE '\{"seq":[0-9]+,"actor":"[^"]*","actor_peer":'"${peer}"'[^}]+\}' | grep '"name":"stroke"' | head -1 || true)
  if [[ -z "$hit" ]]; then
    log "FAIL: $label no stroke with actor_peer=$peer"
    log "json=$json"
    exit 1
  fi
  if ! printf '%s' "$hit" | grep -q '"thumb":true'; then
    log "FAIL: $label actor_peer=$peer thumb!=true entry=$hit"
    exit 1
  fi
  if printf '%s' "$hit" | grep -q '"bbox":null'; then
    log "FAIL: $label actor_peer=$peer bbox=null entry=$hit"
    exit 1
  fi
  if ! printf '%s' "$hit" | grep -qE '"bbox":\[[0-9]+,[0-9]+,[0-9]+,[0-9]+\]'; then
    log "FAIL: $label actor_peer=$peer bbox not array entry=$hit"
    exit 1
  fi
  log "ok $label actor_peer=$peer thumb+bbox"
}

# ---------------------------------------------------------------------------
log "=== solo regression ==="
solo_pid=$(start_pixie "$SOLO_PORT" "$SOLO_OUT")
wait_port "$SOLO_PORT" "$solo_pid"
drive_s 'step 2; action set_tool pen; action set_color 00FF00; action stroke 5 5 40 5; step 2' >/dev/null
drive_s "snapshot history $SOLO_OUT/solo-history.json" >/dev/null
if [[ ! -f "$SOLO_OUT/solo-history.json" ]]; then
  drive_s "snapshot history solo-history.json" >/dev/null
fi
solo_json=$(cat "$SOLO_OUT/solo-history.json" 2>/dev/null || cat "$SOLO_OUT/history.json" 2>/dev/null || true)
if [[ -z "$solo_json" ]]; then
  log "FAIL: solo history snapshot missing; out=$(ls -la "$SOLO_OUT")"
  exit 1
fi
if ! printf '%s' "$solo_json" | grep -q '"name":"stroke"'; then
  log "FAIL: solo no stroke in history: $solo_json"
  exit 1
fi
solo_stroke=$(printf '%s' "$solo_json" | grep -oE '\{"seq":[0-9]+,"actor":"[^"]*","actor_peer":null[^}]*"name":"stroke"[^}]*\}' | head -1 || true)
if [[ -z "$solo_stroke" ]]; then
  solo_stroke=$(printf '%s' "$solo_json" | grep -oE '\{[^}]*"name":"stroke"[^}]*\}' | head -1 || true)
fi
if [[ -z "$solo_stroke" ]]; then
  log "FAIL: solo could not extract stroke entry: $solo_json"
  exit 1
fi
if ! printf '%s' "$solo_stroke" | grep -q '"thumb":true'; then
  log "FAIL: solo thumb!=true: $solo_stroke"
  exit 1
fi
if printf '%s' "$solo_stroke" | grep -q '"bbox":null'; then
  log "FAIL: solo stroke bbox=null: $solo_stroke"
  exit 1
fi
log "solo PASS entry=$solo_stroke"
echo "solo_ok=yes" >"$E2E/result.txt"
quit_pid "$SOLO_PORT" "$solo_pid"
solo_pid=""

# ---------------------------------------------------------------------------
log "=== netsync history thumb E2E ==="
host_pid=$(start_pixie "$HOST_PORT" "$HOST_OUT" KNGN_NETSYNC_HOST=1 KNGN_NETSYNC_PORT="$NETSYNC_PORT")
wait_port "$HOST_PORT" "$host_pid"
client_pid=$(start_pixie "$CLIENT_PORT" "$CLIENT_OUT" KNGN_NETSYNC_CONNECT=127.0.0.1:"$NETSYNC_PORT")
wait_port "$CLIENT_PORT" "$client_pid"

wait_join

drive_h 'step 2; action set_tool pen; action set_color FF0000' >/dev/null
drive_c 'step 2; action set_tool pen; action set_color 0000FF' >/dev/null

# host-origin strokes (actor_peer=0 on both)
drive_h 'action stroke 10 10 60 10; action stroke 10 20 60 20' >/dev/null
wait_drain 2

# client-origin strokes (actor_peer=1 typically)
drive_c 'action stroke 10 30 60 30; action stroke 10 40 60 40' >/dev/null
wait_drain 4

drive_h "snapshot history $HOST_OUT/host-history.json" >/dev/null
drive_c "snapshot history $CLIENT_OUT/client-history.json" >/dev/null
host_json=$(cat "$HOST_OUT/host-history.json")
client_json=$(cat "$CLIENT_OUT/client-history.json")

# On both peers: self and peer origins should have thumb
# host view: peer 0 = self (host), peer 1 = client
# client view: peer 0 = host (peer), peer 1 = self
assert_stroke_thumb "$host_json" 0 "host-view self(host)"
assert_stroke_thumb "$host_json" 1 "host-view peer(client)"
assert_stroke_thumb "$client_json" 0 "client-view peer(host)"
assert_stroke_thumb "$client_json" 1 "client-view self(client)"

{
  echo "solo_ok=yes"
  echo "self_thumb=yes"
  echo "peer_thumb=yes"
} >"$E2E/result.txt"

log "PASS: history thumbs self+peer on host and client"
