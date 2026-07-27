#!/usr/bin/env bash
# Headless verification script: run a program under Xvfb and capture the screen as PNG.
#
# Usage:
#   scripts/xvfb-screenshot.sh <out.png>                 # no client: capture the root window (pipeline smoke)
#   scripts/xvfb-screenshot.sh <out.png> -- <cmd> [args] # start <cmd> → capture after a few frames
#
# Dependencies (provided by the nix devShell): Xvfb(xorg.xorgserver) / xwd(xorg.xwd) / ffmpeg
# Environment:
#   XVFB_DISPLAY   DISPLAY to use (default :99; pick another on collision)
#   XVFB_GEOMETRY  virtual screen size (default 1280x720x24)
#   SETTLE_SECS    seconds to wait after client start before capture (default 1.5)
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

DISPLAY_ID="${XVFB_DISPLAY:-:99}"
GEOMETRY="${XVFB_GEOMETRY:-1280x720x24}"
SETTLE_SECS="${SETTLE_SECS:-1.5}"

for tool in Xvfb xwd ffmpeg; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' is not on PATH (run inside the nix devShell)" >&2; exit 1; }
done

xvfb_pid=""
cmd_pid=""
cleanup() {
  [ -n "$cmd_pid" ] && kill "$cmd_pid" 2>/dev/null || true
  [ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Start Xvfb
Xvfb "$DISPLAY_ID" -screen 0 "$GEOMETRY" >/dev/null 2>&1 &
xvfb_pid=$!

# Normalize the display number (:99 / :99.0 → 99) and build the socket path.
display_num="${DISPLAY_ID#:}"
display_num="${display_num%%.*}"
sock="/tmp/.X11-unix/X${display_num}"

# Wait for the X server socket (up to ~5s). Fail immediately if Xvfb dies (avoid capturing an existing display by mistake).
for _ in $(seq 1 50); do
  kill -0 "$xvfb_pid" 2>/dev/null || { echo "error: Xvfb ($DISPLAY_ID) exited immediately after start" >&2; exit 1; }
  [ -S "$sock" ] && break
  sleep 0.1
done
[ -S "$sock" ] || { echo "error: Xvfb ($DISPLAY_ID) failed to start" >&2; exit 1; }

# When a client is given, start it and wait a few frames
if [ "${#CMD[@]}" -gt 0 ]; then
  DISPLAY="$DISPLAY_ID" "${CMD[@]}" >/dev/null 2>&1 &
  cmd_pid=$!
  sleep "$SETTLE_SECS"
  # Confirm the client is alive before capture (do not treat an instant crash as "success + empty PNG").
  # Set ALLOW_CLIENT_EXIT=1 to allow short-lived clients (draw once and exit).
  if ! kill -0 "$cmd_pid" 2>/dev/null; then
    rc=0
    wait "$cmd_pid" || rc=$?
    cmd_pid=""
    if [ "${ALLOW_CLIENT_EXIT:-0}" = "1" ]; then
      echo "warning: target command exited before capture (exit=$rc). Continuing because ALLOW_CLIENT_EXIT=1." >&2
    else
      # A dead app at capture time is a verification failure. Even a clean exit(0) counts as failure if it exits early (=1).
      echo "error: target command exited before capture (exit=$rc)" >&2
      exit "$(( rc == 0 ? 1 : rc ))"
    fi
  fi
fi

# Grab the root window with xwd → convert to PNG with ffmpeg
tmp_xwd="$(mktemp -t xvfb-shot.XXXXXX.xwd)"
trap 'rm -f "$tmp_xwd"; cleanup' EXIT INT TERM
xwd -root -display "$DISPLAY_ID" -out "$tmp_xwd"
# Unused xwd bytes misread as alpha yield a transparent PNG (alpha=0) that looks white in viewers.
# Force opaque via rgb24.
ffmpeg -y -loglevel error -i "$tmp_xwd" -pix_fmt rgb24 "$OUT"

echo "screenshot -> $OUT (display=$DISPLAY_ID, geometry=$GEOMETRY)"
