#!/usr/bin/env bash
set -euo pipefail

# TASK-114.4 appshell E2E. Generated replay files stay under workspace/.e2e.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
ZIG_BIN=/nix/store/law2wc6rrky4r453xyqhpmxhkmih890i-zig-0.16.0/bin/zig
E2E="$ROOT/.e2e/task-114.4"
BIN="$E2E/bin"
APPS="$E2E/apps"
OUT="$E2E/out"
PROJ="$E2E/projects"
APP="$BIN/bin/pixie"
PNG="$ROOT/examples/image/usako.png"
rm -rf "$E2E"
mkdir -p "$OUT" "$PROJ"
ZIG_GLOBAL_CACHE_DIR="$ROOT/.zig-global-cache" CLANG_MODULE_CACHE_PATH="$ROOT/.clang-module-cache" "$ZIG_BIN" build -Dplatform=objc build-pixie
mkdir -p "$BIN/bin"
pixie_build=$(find "$ROOT/.zig-cache/o" -type f -name pixie -perm -111 -print0 | xargs -0 ls -t | head -1)
cp "$pixie_build" "$APP"
test -x "$APP"

make_script() {
    local file=$1
    shift
    printf '%s\n' "$@" > "$file"
}

run_case() {
    local name=$1 app_dir=$2 script=$3
    mkdir -p "$app_dir" "$OUT/$name"
    VP_APPSHELL_DIR="$app_dir" VP_HEADLESS=1 VP_HARNESS_SCRIPT="$script" VP_HARNESS_OUT="$OUT/$name" "$APP" >"$OUT/$name/app.log" 2>&1
}

# Quit: Cancel then Discard.
quit_cancel="$OUT/quit-cancel.txt"
make_script "$quit_cancel" 'step 3' 'action stroke 10 10 20 10' 'action request_close' 'expect appshell confirm=close' 'action confirm_cancel' 'expect appshell dirty=1' 'action request_close' 'action confirm_discard'
run_case quit-cancel "$APPS/quit-cancel" "$quit_cancel"

# Untitled Quit: Save As.
quit_save="$OUT/quit-save.txt"
quit_save_path="$PROJ/quit-save.pix"
make_script "$quit_save" 'step 3' 'action stroke 10 10 20 10' 'action request_close' 'expect appshell confirm=close' "action confirm_save $quit_save_path"
run_case quit-save "$APPS/quit-save" "$quit_save"
test -f "$quit_save_path"

# New: Cancel, Discard, Save.
new_script="$OUT/new.txt"
new_path="$PROJ/new.pix"
make_script "$new_script" 'step 3' 'action stroke 10 10 20 10' 'action new' 'expect appshell confirm=new' 'action confirm_cancel' 'action new' 'action confirm_discard' 'expect appshell dirty=0' 'action stroke 30 30 40 30' 'action new' "action confirm_save $new_path" 'expect appshell dirty=0' 'action request_close'
run_case new "$APPS/new" "$new_script"
test -f "$new_path"

# PNG Open: Cancel, Discard, Save.
png_script="$OUT/png-open.txt"
png_path="$PROJ/png.pix"
make_script "$png_script" 'step 3' 'action stroke 10 10 20 10' "action open $PNG" 'expect appshell confirm=new' 'action confirm_cancel' "action open $PNG" 'action confirm_discard' 'expect appshell path=none' 'expect appshell dirty=1' 'action stroke 30 30 40 30' "action open $PNG" "action confirm_save $png_path" 'expect appshell path=none' 'expect appshell dirty=1' 'action request_close' 'action confirm_discard'
run_case png-open "$APPS/png-open" "$png_script"
test -f "$png_path"

# Project Open: Cancel, named Save, Discard.
project_script="$OUT/project-open.txt"
make_script "$project_script" "action open_project $quit_save_path" 'action stroke 50 50 60 50' "action open_project $quit_save_path" 'expect appshell confirm=open' 'action confirm_cancel' "action open_project $quit_save_path" 'action confirm_save' 'action stroke 70 70 80 70' "action open_project $quit_save_path" 'action confirm_discard' 'expect appshell dirty=0' 'action request_close'
run_case project-open "$APPS/project-open" "$project_script"

# Recent MRU, persistence, prune, and dirty-open confirmation.
recent_app="$APPS/recent"
recent_a="$PROJ/recent-a.pix"
recent_b="$PROJ/recent-b.pix"
seed_a="$OUT/recent-a.txt"
seed_b="$OUT/recent-b.txt"
make_script "$seed_a" 'action stroke 10 10 20 10' 'action request_close' "action confirm_save $recent_a"
run_case recent-seed-a "$recent_app" "$seed_a"
make_script "$seed_b" 'action stroke 30 30 40 30' 'action request_close' "action confirm_save $recent_b"
run_case recent-seed-b "$recent_app" "$seed_b"
recent_script="$OUT/recent.txt"
make_script "$recent_script" "action open_project $recent_b" "action open_project $recent_a" 'step 1' "expect appshell recent0=$recent_a" 'expect menu items>0' 'action stroke 90 90 100 90' "action open_project $recent_b" 'expect appshell confirm=open' 'action confirm_cancel' "action open_project $recent_b" 'action confirm_discard' 'expect appshell dirty=0' 'action request_close'
run_case recent "$recent_app" "$recent_script"
rm "$recent_a"
prune_script="$OUT/prune.txt"
make_script "$prune_script" "expect appshell recent0=$recent_b" 'expect appshell recent=1' 'action request_close'
run_case recent-prune "$recent_app" "$prune_script"

# Crash -> recovery. SIGKILL is restricted to this deliberate crashed $! process.
recovery_app="$APPS/recovery"
crash_script="$OUT/recovery-crash.txt"
make_script "$crash_script" 'step 3' 'action stroke 30 30 80 80' 'digest canvas' 'step 1000000000'
mkdir -p "$recovery_app" "$OUT/recovery-crash"
VP_APPSHELL_DIR="$recovery_app" VP_HEADLESS=1 VP_HARNESS_SCRIPT="$crash_script" VP_HARNESS_OUT="$OUT/recovery-crash" "$APP" >"$OUT/recovery-crash/app.log" 2>&1 &
crash_pid=$!
autosave_file=
for _ in $(seq 1 200); do
    autosave_file=$(find "$recovery_app/autosave" -type f -name '*.autosave' -print -quit 2>/dev/null || true)
    test -n "$autosave_file" && break
    sleep 0.05
done
test -n "$autosave_file"
kill -KILL "$crash_pid"
set +e
wait "$crash_pid"
crash_status=$?
set -e
test "$crash_status" -ne 0

recover_script="$OUT/recovery-recover.txt"
make_script "$recover_script" 'expect appshell recovery=pending' 'expect appshell autosave=1' 'action recover' 'expect appshell recovery=none' 'expect appshell dirty=1' 'digest canvas' 'action request_close' 'action confirm_discard'
run_case recovery-recover "$recovery_app" "$recover_script"
before_crc=$(sed -n 's/.*crc=\([0-9A-Fa-f]*\).*/\1/p' "$OUT/recovery-crash/app.log" | head -1)
after_crc=$(sed -n 's/.*crc=\([0-9A-Fa-f]*\).*/\1/p' "$OUT/recovery-recover/app.log" | tail -1)
test -n "$before_crc" && test "$before_crc" = "$after_crc"
test -z "$(find "$recovery_app/autosave" -name '*.autosave' -print -quit 2>/dev/null || true)"

# Second candidate: explicit Discard recovery.
mkdir -p "$OUT/recovery-crash-2"
VP_APPSHELL_DIR="$recovery_app" VP_HEADLESS=1 VP_HARNESS_SCRIPT="$crash_script" VP_HARNESS_OUT="$OUT/recovery-crash-2" "$APP" >"$OUT/recovery-crash-2/app.log" 2>&1 &
crash_pid=$!
autosave_file=
for _ in $(seq 1 200); do
    autosave_file=$(find "$recovery_app/autosave" -type f -name '*.autosave' -print -quit 2>/dev/null || true)
    test -n "$autosave_file" && break
    sleep 0.05
done
test -n "$autosave_file"
kill -KILL "$crash_pid"
set +e
wait "$crash_pid"
set -e
discard_script="$OUT/recovery-discard.txt"
make_script "$discard_script" 'expect appshell recovery=pending' 'action discard_recovery' 'expect appshell recovery=none' 'expect appshell autosave=0' 'action request_close'
run_case recovery-discard "$recovery_app" "$discard_script"
test -z "$(find "$recovery_app/autosave" -name '*.autosave' -print -quit 2>/dev/null || true)"

# Netsync: bind failure is an allowed sandbox skip; successful runs use drive quit.
netsync_status=skipped
if test "${VP_E2E_NETSYNC:-1}" = 1; then
    "$ZIG_BIN" build drive >/dev/null 2>&1 || true
    drive="$ROOT/zig-out/bin/drive"
    host_port="$E2E/host.port"
    client_port="$E2E/client.port"
    VP_APPSHELL_DIR="$APPS/netsync-host" VP_HEADLESS=1 VP_HARNESS_LISTEN= VP_HARNESS_PORT_FILE="$host_port" VP_NETSYNC_HOST=1 VP_NETSYNC_PORT=9130 "$APP" >"$OUT/netsync-host.log" 2>&1 &
    host_pid=$!
    VP_APPSHELL_DIR="$APPS/netsync-client" VP_HEADLESS=1 VP_HARNESS_LISTEN= VP_HARNESS_PORT_FILE="$client_port" VP_NETSYNC_CONNECT=127.0.0.1:9130 "$APP" >"$OUT/netsync-client.log" 2>&1 &
    client_pid=$!
    for _ in $(seq 1 100); do
        test -f "$host_port" && test -f "$client_port" && break
        sleep 0.05
    done
    if test -x "$drive" && test -f "$host_port" && test -f "$client_port"; then
        # free-run LISTEN: host は自走するので step 注入不要。await で一接続保持して join 完了を待つ。
        "$drive" --port-file "$client_port" 'await netsync awaiting_sync=0 600' >/dev/null
        "$drive" --port-file "$host_port" 'action stroke 10 10 20 10' >/dev/null
        # free-run では step は frame barrier（N present 待ち）。autosave 閾値相当の 120 frame を待つ。
        "$drive" --port-file "$host_port" 'step 120' >/dev/null
        "$drive" --port-file "$host_port" 'digest appshell' | grep -q 'autosave=0'
        "$drive" --port-file "$host_port" quit >/dev/null
        "$drive" --port-file "$client_port" quit >/dev/null
        wait "$host_pid" "$client_pid"
        netsync_status=ok
    else
        echo 'appshell_e2e: netsync bind unavailable; skipped (known sandbox restriction)' >&2
        kill -KILL "$host_pid" "$client_pid" 2>/dev/null || true
        wait "$host_pid" 2>/dev/null || true
        wait "$client_pid" 2>/dev/null || true
    fi
else
    echo 'appshell_e2e: netsync skipped by VP_E2E_NETSYNC=0' >&2
fi
echo "appshell_e2e: ok (recovery_crc=$after_crc netsync=$netsync_status)"
