#!/usr/bin/env bash
# History thumbnails during netsync (self/peer both thumb=true, bbox!=null) + solo regression.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MAIN="${VP_MAIN_DIR:-$ROOT}"
DRIVE="$ROOT/scripts/drive"
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

start_pixie() {
  local port_file=$1 out_dir=$2
  shift 2
  mkdir -p "$out_dir"
  rm -f "$port_file"
  env VP_HARNESS_HEADLESS=1 VP_HARNESS_LIVE=1 VP_HARNESS_PORT_FILE="$port_file" VP_HARNESS_OUT="$out_dir" "$@" \
    direnv exec "$MAIN" zig build run-pixie >"$out_dir/app.log" 2>&1 &
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
  "$DRIVE" --port-file "$port_file" 'quit' >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  log "WARN: pid $pid still alive after quit"
}

host_pid=""; client_pid=""; solo_pid=""
cleanup() {
  quit_pid "$HOST_PORT" "${host_pid:-}" 2>/dev/null || true
  quit_pid "$CLIENT_PORT" "${client_pid:-}" 2>/dev/null || true
  quit_pid "$SOLO_PORT" "${solo_pid:-}" 2>/dev/null || true
}
trap cleanup EXIT

drive_h() { "$DRIVE" --port-file "$HOST_PORT" "$1"; }
drive_c() { "$DRIVE" --port-file "$CLIENT_PORT" "$1"; }
drive_s() { "$DRIVE" --port-file "$SOLO_PORT" "$1"; }

parse_kv() {
  local text=$1 key=$2
  printf '%s' "$text" | grep -oE "${key}=[^ ]+" | head -1 | cut -d= -f2-
}

wait_drain() {
  local min_seq=$1
  local i ho co hs cs hp cp
  for i in $(seq 1 4000); do
    drive_h 'step 1' >/dev/null 2>&1 || true
    drive_c 'step 1' >/dev/null 2>&1 || true
    ho=$(drive_h 'digest netsync' 2>/dev/null || true)
    co=$(drive_c 'digest netsync' 2>/dev/null || true)
    hs=$(parse_kv "$ho" last_seq); hs=${hs:-0}
    cs=$(parse_kv "$co" last_seq); cs=${cs:-0}
    hp=$(parse_kv "$ho" pending); hp=${hp:-9}
    cp=$(parse_kv "$co" pending); cp=${cp:-9}
    if [[ "$hp" == "0" && "$cp" == "0" && "$hs" -ge "$min_seq" && "$cs" -ge "$min_seq" ]]; then
      return 0
    fi
    sleep 0.05
  done
  log "FAIL: drain timeout min_seq=$min_seq host='$ho' client='$co'"
  exit 1
}

# Assert history JSON has stroke with actor_peer=P, thumb=true, bbox not null
assert_stroke_thumb() {
  local json=$1 peer=$2 label=$3
  # Extract stroke objects; look for actor_peer matching
  if ! printf '%s' "$json" | grep -qE "\"name\":\"stroke\"[^}]*\"actor_peer\":${peer}" \
    && ! printf '%s' "$json" | grep -qE "\"actor_peer\":${peer}[^}]*\"name\":\"stroke\""; then
    # order of keys is fixed: actor_peer before name... actually actor then actor_peer then kind then name
    :
  fi
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
solo_hist=$(drive_s "snapshot history $SOLO_OUT/solo-history.json" 2>/dev/null || true)
solo_json=$(cat "$SOLO_OUT/solo-history.json" 2>/dev/null || true)
if [[ -z "$solo_json" ]]; then
  # snapshot may write relative to harness out; try digest path
  solo_json=$(drive_s 'snapshot history' 2>/dev/null; ls -la "$SOLO_OUT"/ 2>/dev/null; find "$SOLO_OUT" -name '*history*' 2>/dev/null)
fi
# Re-fetch: snapshot history <path> writes file; also try without path under VP_HARNESS_OUT
if [[ ! -f "$SOLO_OUT/solo-history.json" ]]; then
  drive_s "snapshot history solo-history.json" >/dev/null 2>&1 || true
fi
# harness writes under VP_HARNESS_OUT when relative
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
  # fallback: any stroke object
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
host_pid=$(start_pixie "$HOST_PORT" "$HOST_OUT" VP_NETSYNC_HOST=1 VP_NETSYNC_PORT="$NETSYNC_PORT")
wait_port "$HOST_PORT" "$host_pid"
client_pid=$(start_pixie "$CLIENT_PORT" "$CLIENT_OUT" VP_NETSYNC_CONNECT=127.0.0.1:"$NETSYNC_PORT")
wait_port "$CLIENT_PORT" "$client_pid"

# join
for i in $(seq 1 2000); do
  drive_h 'step 1' >/dev/null 2>&1 || true
  out=$(drive_c 'step 1; digest netsync' 2>/dev/null || true)
  printf '%s' "$out" | grep -q 'awaiting_sync=0' && break
  sleep 0.05
done

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
