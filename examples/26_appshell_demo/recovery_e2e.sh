#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
ZIG_BIN=${ZIG_BIN:-/nix/store/law2wc6rrky4r453xyqhpmxhkmih890i-zig-0.16.0/bin/zig}
PREFIX="$ROOT/.e2e/recovery-bin"
APP_DIR="$ROOT/.e2e/recovery-app"
OUT_DIR="$ROOT/.e2e/recovery-out"
CRASH_SCRIPT="$ROOT/.e2e/recovery-crash.txt"
RECOVER_SCRIPT="$ROOT/.e2e/recovery-recover.txt"
SAVE_SCRIPT="$ROOT/.e2e/recovery-save.txt"
DISCARD_SCRIPT="$ROOT/.e2e/recovery-discard.txt"
CRASH_LOG="$OUT_DIR/crash.log"
RECOVER_LOG="$OUT_DIR/recover.log"
SAVE_LOG="$OUT_DIR/save.log"
DISCARD_LOG="$OUT_DIR/discard.log"

rm -rf "$PREFIX" "$APP_DIR" "$OUT_DIR"
mkdir -p "$OUT_DIR"

cat > "$CRASH_SCRIPT" <<'EOF'
action draw_stroke 30 30 80 80
digest doodle
step 1000000000
EOF
cat > "$RECOVER_SCRIPT" <<'EOF'
expect doodle recovery=pending
expect doodle autosave=1
action recover
expect doodle dirty=1
expect doodle recovery=none
digest doodle
action request_close
action confirm_discard
quit
EOF
cat > "$SAVE_SCRIPT" <<EOF
action draw_stroke 30 30 80 80
step 70
expect doodle autosave=1
action request_close
action confirm_save $APP_DIR/saved.pix
expect doodle dirty=0
quit
EOF
cat > "$DISCARD_SCRIPT" <<'EOF'
action draw_stroke 30 30 80 80
step 70
expect doodle autosave=1
action request_close
action confirm_discard
quit
EOF

(cd "$SCRIPT_DIR" && ZIG_GLOBAL_CACHE_DIR="$ROOT/.zig-global-cache" "$ZIG_BIN" build -Dplatform=objc install --prefix "$PREFIX")
APP_BIN="$PREFIX/bin/example_26_appshell_demo"
test -x "$APP_BIN"

VP_APPSHELL_DIR="$APP_DIR" \
VP_HARNESS_HEADLESS=1 \
VP_HARNESS_SCRIPT="$CRASH_SCRIPT" \
VP_HARNESS_OUT="$OUT_DIR/crash" \
"$APP_BIN" >"$CRASH_LOG" 2>&1 &
app_pid=$!

autosave_file=""
for _ in $(seq 1 200); do
    autosave_file=$(find "$APP_DIR/autosave" -type f -name '*.autosave' -print -quit 2>/dev/null || true)
    if test -n "$autosave_file"; then break; fi
    kill -0 "$app_pid" 2>/dev/null || true
    sleep 0.05
done
test -n "$autosave_file"

kill -KILL "$app_pid"
set +e
wait "$app_pid"
crash_status=$?
set -e
test "$crash_status" -ne 0

VP_APPSHELL_DIR="$APP_DIR" \
VP_HARNESS_HEADLESS=1 \
VP_HARNESS_SCRIPT="$RECOVER_SCRIPT" \
VP_HARNESS_OUT="$OUT_DIR/recover" \
"$APP_BIN" >"$RECOVER_LOG" 2>&1

before_crc=$(sed -n 's/.*canvas_crc=\([0-9A-Fa-f]*\).*/\1/p' "$CRASH_LOG" | head -n 1)
after_crc=$(sed -n 's/.*canvas_crc=\([0-9A-Fa-f]*\).*/\1/p' "$RECOVER_LOG" | tail -n 1)
test -n "$before_crc"
test -n "$after_crc"
test "$before_crc" = "$after_crc"

residual=$(find "$APP_DIR/autosave" -type f -name '*.autosave' -print -quit 2>/dev/null || true)
test -z "$residual"

VP_APPSHELL_DIR="$APP_DIR" \
VP_HARNESS_HEADLESS=1 \
VP_HARNESS_SCRIPT="$SAVE_SCRIPT" \
VP_HARNESS_OUT="$OUT_DIR/save" \
"$APP_BIN" >"$SAVE_LOG" 2>&1
test -f "$APP_DIR/saved.pix"
residual=$(find "$APP_DIR/autosave" -type f -name '*.autosave' -print -quit 2>/dev/null || true)
test -z "$residual"

VP_APPSHELL_DIR="$APP_DIR" \
VP_HARNESS_HEADLESS=1 \
VP_HARNESS_SCRIPT="$DISCARD_SCRIPT" \
VP_HARNESS_OUT="$OUT_DIR/discard" \
"$APP_BIN" >"$DISCARD_LOG" 2>&1
residual=$(find "$APP_DIR/autosave" -type f -name '*.autosave' -print -quit 2>/dev/null || true)
test -z "$residual"

echo "recovery_e2e: ok (pid=$app_pid canvas_crc=$after_crc residual=0)"
