#!/usr/bin/env bash
# Retained AI overlay: harness inject → digest counts → clear → empty.
# Replay transport (no live process, no pkill). Work dirs are mktemp.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MAIN="${KNGN_MAIN_DIR:-$ROOT}"

log() { printf '%s\n' "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kngn-overlay-e2e-XXXXXX")
APPDIR=$(mktemp -d "${TMPDIR:-/tmp}/kngn-overlay-appshell-XXXXXX")
OUT="$WORK/out"
SCRIPT="$WORK/script.txt"
mkdir -p "$OUT"

cleanup() {
  # Leave $WORK for diagnosis; /tmp reclaims it. APPDIR is scratch prefs only.
  rm -rf "$APPDIR"
}
trap cleanup EXIT

cd "$ROOT"

cat > "$SCRIPT" <<'EOF'
step 2
action overlay_set cmd=rect_filled x=220 y=80 w=160 h=36 color=#FFFFCC00 clip_x=0 clip_y=0 clip_w=780 clip_h=600 cmd=line x0=300 y0=118 x1=380 y1=220 thickness=3 color=#FFFF8800 clip_x=0 clip_y=0 clip_w=780 clip_h=600 cmd=text x=226 y=86 color=#FF201000 text="look here"
step 1
digest overlay
expect overlay contains rect_filled=1
expect overlay contains line=1
expect overlay contains text=1
snapshot fb
action overlay_clear
step 1
digest overlay
expect overlay contains rect_filled=0
expect overlay contains line=0
expect overlay contains text=0
quit
EOF

direnv exec "$MAIN" zig build build-pixie
PIXIE="$ROOT/zig-out/bin/pixie"
test -x "$PIXIE" || fail "pixie binary missing at $PIXIE"

KNGN_APPSHELL_DIR="$APPDIR" KNGN_HEADLESS=1 \
  KNGN_HARNESS_SCRIPT="$SCRIPT" KNGN_HARNESS_OUT="$OUT" \
  "$PIXIE" >"$OUT/app.log" 2>&1

grep -q 'expect ok' "$OUT/app.log" || fail "no expect ok in app.log"
grep -q 'rect_filled=1' "$OUT/app.log" || fail "overlay set did not report rect_filled=1"
grep -q 'rect_filled=0' "$OUT/app.log" || fail "overlay clear did not report rect_filled=0"
test -f "$OUT"/frame_*.png || fail "snapshot fb did not write a PNG under $OUT"

log "overlay-ai-channel e2e: ok (out=$OUT)"
