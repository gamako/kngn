#!/usr/bin/env bash
# Verification script: run a program on a headless Wayland compositor and capture the screen as PNG.
# Wayland counterpart of the X11 scripts/xvfb-screenshot.sh.
#
# Usage:
#   scripts/wayland-screenshot.sh <out.png>                 # no client: capture compositor output (smoke)
#   scripts/wayland-screenshot.sh <out.png> -- <cmd> [args] # start <cmd> → capture after a few frames
#
# Dependencies (provided by the nix devShell):
#   - sway path (default): sway(WLR_BACKENDS=headless) + grim
#   - weston path        : weston(headless backend) + weston-screenshooter
# Environment:
#   WAYLAND_SHOT_COMPOSITOR  sway | weston (default sway)
#   WAYLAND_SHOT_DISPLAY     weston socket name (default wayland-vp; sway auto-numbers and we detect it)
#   WAYLAND_SHOT_GEOMETRY    WxH (default 1280x720)
#   COMPOSITOR_SETTLE_SECS   seconds to wait after the socket appears for output ready (default 0.5; headless output lag)
#   SETTLE_SECS              seconds to wait after client start before capture (default 1.5)
#   ALLOW_CLIENT_EXIT        if 1, continue even if the client exits before capture (default 0 = treat as failure)
#
# Note: headless compositor startup, output names, and screenshooter permissions are Linux-machine dependent,
# so real launch/capture must be tuned on a Linux host. Cannot run on macOS (bash -n syntax check only).
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <out.png> [-- command args...]" >&2
  exit 2
fi

OUT="$1"; shift
CMD=()
if [ "${1:-}" = "--" ]; then
  shift
  CMD=("$@")
fi

COMPOSITOR="${WAYLAND_SHOT_COMPOSITOR:-sway}"
GEOMETRY="${WAYLAND_SHOT_GEOMETRY:-1280x720}"
W="${GEOMETRY%x*}"
H="${GEOMETRY#*x}"
SETTLE_SECS="${SETTLE_SECS:-1.5}"

# Check required tools per compositor.
case "$COMPOSITOR" in
  sway)   tools=(sway grim) ;;
  weston) tools=(weston weston-screenshooter) ;;
  *) echo "error: WAYLAND_SHOT_COMPOSITOR must be sway or weston (got: $COMPOSITOR)" >&2; exit 2 ;;
esac
for tool in "${tools[@]}"; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' is not on PATH (run inside the nix devShell)" >&2; exit 1; }
done

# Use a dedicated XDG_RUNTIME_DIR so the socket does not collide with an existing session.
runtime_dir="$(mktemp -d -t wl-shot.XXXXXX)"
chmod 700 "$runtime_dir"
export XDG_RUNTIME_DIR="$runtime_dir"

comp_pid=""
cmd_pid=""
sway_config=""
shot_dir=""
cleanup() {
  [ -n "$cmd_pid" ] && kill "$cmd_pid" 2>/dev/null || true
  [ -n "$comp_pid" ] && kill "$comp_pid" 2>/dev/null || true
  [ -n "$sway_config" ] && rm -f "$sway_config" 2>/dev/null || true
  [ -n "$shot_dir" ] && rm -rf "$shot_dir" 2>/dev/null || true
  rm -rf "$runtime_dir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Start the compositor headless and settle WAYLAND_DISPLAY.
if [ "$COMPOSITOR" = "sway" ]; then
  # sway requires a config. Minimal (headless output resolution only). Output name/startup may need host tuning.
  sway_config="$(mktemp -t wl-shot-sway.XXXXXX.conf)"
  printf 'output HEADLESS-1 resolution %sx%s\n' "$W" "$H" > "$sway_config"
  WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 sway -c "$sway_config" >/dev/null 2>&1 &
  comp_pid=$!
  # wlroots auto-numbers wayland-N under XDG_RUNTIME_DIR. Adopt whichever appears.
  WAYLAND_DISPLAY=""
  for _ in $(seq 1 100); do
    kill -0 "$comp_pid" 2>/dev/null || { echo "error: sway (headless) exited immediately after start" >&2; exit 1; }
    sock="$(ls "$runtime_dir"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -n1 || true)"
    [ -n "$sock" ] && [ -S "$sock" ] && { WAYLAND_DISPLAY="$(basename "$sock")"; break; }
    sleep 0.1
  done
else
  WAYLAND_DISPLAY="${WAYLAND_SHOT_DISPLAY:-wayland-vp}"
  weston --backend=headless-backend.so --socket="$WAYLAND_DISPLAY" --width="$W" --height="$H" >/dev/null 2>&1 &
  comp_pid=$!
  for _ in $(seq 1 100); do
    kill -0 "$comp_pid" 2>/dev/null || { echo "error: weston (headless) exited immediately after start" >&2; exit 1; }
    [ -S "$runtime_dir/$WAYLAND_DISPLAY" ] && break
    sleep 0.1
  done
fi

if [ -z "${WAYLAND_DISPLAY:-}" ] || [ ! -S "$runtime_dir/$WAYLAND_DISPLAY" ]; then
  echo "error: Wayland socket for $COMPOSITOR did not appear (check headless startup on a Linux host)" >&2
  exit 1
fi
export WAYLAND_DISPLAY

# Right after the socket appears, output creation/config may still be incomplete (headless). Wait briefly before draw/capture.
sleep "${COMPOSITOR_SETTLE_SECS:-0.5}"

# When a client is given, start it and wait a few frames.
if [ "${#CMD[@]}" -gt 0 ]; then
  "${CMD[@]}" >/dev/null 2>&1 &
  cmd_pid=$!
  sleep "$SETTLE_SECS"
  # Confirm the client is alive before capture (do not treat an instant crash as "success + empty PNG").
  if ! kill -0 "$cmd_pid" 2>/dev/null; then
    rc=0
    wait "$cmd_pid" || rc=$?
    cmd_pid=""
    if [ "${ALLOW_CLIENT_EXIT:-0}" = "1" ]; then
      echo "warning: target command exited before capture (exit=$rc). Continuing because ALLOW_CLIENT_EXIT=1." >&2
    else
      echo "error: target command exited before capture (exit=$rc)" >&2
      exit "$(( rc == 0 ? 1 : rc ))"
    fi
  fi
fi

# Take the screenshot (method depends on the compositor).
if [ "$COMPOSITOR" = "sway" ]; then
  grim "$OUT"
else
  # weston-screenshooter writes a time-stamped file under cwd by default, so shoot in a tmp cwd and move to $OUT.
  # shot_dir is removed by the cleanup trap (gone even on failure / mv failure / set -e exit).
  shot_dir="$(mktemp -d -t wl-shot-out.XXXXXX)"
  ( cd "$shot_dir" && weston-screenshooter )
  produced="$(ls "$shot_dir"/*.png 2>/dev/null | head -n1 || true)"
  if [ -z "$produced" ]; then
    echo "error: weston-screenshooter did not produce a PNG" >&2
    exit 1
  fi
  mv "$produced" "$OUT"
fi

echo "screenshot -> $OUT (compositor=$COMPOSITOR, display=$WAYLAND_DISPLAY, geometry=${W}x${H})"
