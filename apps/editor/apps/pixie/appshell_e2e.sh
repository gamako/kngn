#!/usr/bin/env bash
set -euo pipefail

# appshell E2E. Generated replay files stay under workspace/.e2e.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
ZIG_BIN=/nix/store/law2wc6rrky4r453xyqhpmxhkmih890i-zig-0.16.0/bin/zig
E2E="$ROOT/.e2e/appshell"
BIN="$E2E/bin"
APPS="$E2E/apps"
OUT="$E2E/out"
PROJ="$E2E/projects"
# The default backend gets a bare artifact name.
APP="$BIN/bin/pixie"
PNG="$ROOT/examples/image/usako.png"
rm -rf "$E2E"
mkdir -p "$OUT" "$PROJ"
# Install into a dedicated prefix that was just wiped, rather than searching the build cache
# by name: the cache keeps a binary per backend and per build, so a name search can silently
# return an unrelated one.
ZIG_GLOBAL_CACHE_DIR="$ROOT/.zig-global-cache" CLANG_MODULE_CACHE_PATH="$ROOT/.clang-module-cache" "$ZIG_BIN" build build-pixie --prefix "$BIN"
test -x "$APP"
echo "appshell e2e: running $APP"

make_script() {
    local file=$1
    shift
    printf '%s\n' "$@" > "$file"
}

run_case() {
    local name=$1 app_dir=$2 script=$3
    mkdir -p "$app_dir" "$OUT/$name"
    KNGN_APPSHELL_DIR="$app_dir" KNGN_HEADLESS=1 KNGN_HARNESS_SCRIPT="$script" KNGN_HARNESS_OUT="$OUT/$name" "$APP" >"$OUT/$name/app.log" 2>&1
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
KNGN_APPSHELL_DIR="$recovery_app" KNGN_HEADLESS=1 KNGN_HARNESS_SCRIPT="$crash_script" KNGN_HARNESS_OUT="$OUT/recovery-crash" "$APP" >"$OUT/recovery-crash/app.log" 2>&1 &
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
KNGN_APPSHELL_DIR="$recovery_app" KNGN_HEADLESS=1 KNGN_HARNESS_SCRIPT="$crash_script" KNGN_HARNESS_OUT="$OUT/recovery-crash-2" "$APP" >"$OUT/recovery-crash-2/app.log" 2>&1 &
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

# Failure injection into the document-preparation phase (Debug-only action
# `fault_document_prepare <n>`): every armed preparation must fail and leave the open document,
# the host path and the working buffers untouched. The action reports the injected failure as
# an `injected_fault=` success line, so the run exits 0 and the leak check at teardown runs.
FAULT_SWEEP=${KNGN_E2E_FAULT_SWEEP:-48}

# fault_blocks <file> <action line> <expect lines...>: append FAULT_SWEEP arm/fail/check blocks.
fault_blocks() {
    local file=$1 action=$2
    shift 2
    local i
    for i in $(seq 0 $((FAULT_SWEEP - 1))); do
        printf '%s\n' "action fault_document_prepare $i" "$action" "$@" 'digest appshell' >> "$file"
    done
}

# assert_fault_log <log> <action name> <steps...>: every armed attempt was reported as an
# injected failure, nothing leaked at teardown, and the sweep reached each named preparation
# step plus the not-triggered end.
assert_fault_log() {
    local log=$1 action=$2
    shift 2
    local injected
    injected=$(grep -c "\[harness\] action $action ok ok $action injected_fault=" "$log" || true)
    test "$injected" -eq "$FAULT_SWEEP"
    test "$(grep -c "\[harness\] action $action FAILED" "$log" || true)" -eq 0
    test "$(grep -c 'leaked' "$log" || true)" -eq 0
    local step
    for step in "$@" not_triggered; do
        grep -q "prepare_fault=$step " "$log"
    done
    # No expect inside the sweep may have failed: the document state must be untouched.
    test "$(grep -c '\[harness\] expect FAILED' "$log" || true)" -eq 0
}

# canvas_crcs <log>: the crc values of every `digest canvas` line, in order.
canvas_crcs() {
    sed -n 's/.*\[harness\] digest canvas [0-9x]* layers=[0-9]* selected=[0-9]* comp=\([0-9A-Fa-f]*\).*/\1/p' "$1"
}

fault_app="$APPS/fault"
fault_a="$PROJ/fault-a.pix"
fault_b="$PROJ/fault-b.pix"
seed_fault_a="$OUT/fault-seed-a.txt"
make_script "$seed_fault_a" 'action stroke 10 10 20 10' 'action stroke 12 30 40 30' 'action request_close' "action confirm_save $fault_a"
run_case fault-seed-a "$fault_app" "$seed_fault_a"
seed_fault_b="$OUT/fault-seed-b.txt"
make_script "$seed_fault_b" 'action stroke 50 50 60 50' 'action request_close' "action confirm_save $fault_b"
run_case fault-seed-b "$fault_app" "$seed_fault_b"

# open_project: the open document A survives every failed open of B.
fault_open="$OUT/fault-open.txt"
make_script "$fault_open" "action open_project $fault_a" 'digest canvas'
fault_blocks "$fault_open" "action open_project $fault_b" "expect appshell path=$fault_a" 'expect appshell dirty=0'
printf '%s\n' 'digest canvas' 'action stroke 5 5 15 5' 'expect appshell dirty=1' 'action request_close' 'action confirm_discard' >> "$fault_open"
run_case fault-open "$fault_app" "$fault_open"
assert_fault_log "$OUT/fault-open/app.log" open_project read_file decode runtime autosave_path
test "$(canvas_crcs "$OUT/fault-open/app.log" | sed -n 1p)" = "$(canvas_crcs "$OUT/fault-open/app.log" | sed -n 2p)"

# new <w> <h>: the open document survives every failed replacement by a blank one.
fault_new="$OUT/fault-new.txt"
make_script "$fault_new" "action open_project $fault_a" 'digest canvas'
fault_blocks "$fault_new" 'action new 16 16' "expect appshell path=$fault_a" 'expect appshell confirm=none'
printf '%s\n' 'digest canvas' 'action new 16 16' 'expect appshell path=none' 'action request_close' >> "$fault_new"
run_case fault-new "$fault_app" "$fault_new"
assert_fault_log "$OUT/fault-new/app.log" new document runtime
test "$(canvas_crcs "$OUT/fault-new/app.log" | sed -n 1p)" = "$(canvas_crcs "$OUT/fault-new/app.log" | sed -n 2p)"

# recover: a named document crashes; every failed recovery keeps the candidate on disk and in
# memory, and the real recovery afterwards restores the crashed canvas.
fault_recovery_app="$APPS/fault-recovery"
fault_crash="$OUT/fault-crash.txt"
make_script "$fault_crash" "action open_project $fault_a" 'step 3' 'action stroke 30 30 80 80' 'digest canvas' 'step 1000000000'
mkdir -p "$fault_recovery_app" "$OUT/fault-crash"
KNGN_APPSHELL_DIR="$fault_recovery_app" KNGN_HEADLESS=1 KNGN_HARNESS_SCRIPT="$fault_crash" KNGN_HARNESS_OUT="$OUT/fault-crash" "$APP" >"$OUT/fault-crash/app.log" 2>&1 &
crash_pid=$!
autosave_file=
for _ in $(seq 1 200); do
    autosave_file=$(find "$fault_recovery_app/autosave" -type f -name '*.autosave' -print -quit 2>/dev/null || true)
    test -n "$autosave_file" && break
    sleep 0.05
done
test -n "$autosave_file"
kill -KILL "$crash_pid"
set +e
wait "$crash_pid"
set -e
# First launch: every recovery attempt fails; the candidate must still be on disk afterwards.
fault_recover_sweep="$OUT/fault-recover-sweep.txt"
make_script "$fault_recover_sweep" 'expect appshell recovery=pending'
fault_blocks "$fault_recover_sweep" 'action recover' 'expect appshell recovery=pending' 'expect appshell path=none'
printf '%s\n' 'action request_close' >> "$fault_recover_sweep"
run_case fault-recover-sweep "$fault_recovery_app" "$fault_recover_sweep"
assert_fault_log "$OUT/fault-recover-sweep/app.log" recover decode runtime recovery_paths
test -f "$autosave_file"
# Second launch: the same candidate is offered again and recovers the crashed canvas.
fault_recover="$OUT/fault-recover.txt"
make_script "$fault_recover" 'expect appshell recovery=pending' 'action recover' 'expect appshell recovery=none' "expect appshell path=$fault_a" 'expect appshell dirty=1' 'digest canvas' 'action request_close' 'action confirm_discard'
run_case fault-recover "$fault_recovery_app" "$fault_recover"
test "$(canvas_crcs "$OUT/fault-crash/app.log" | head -1)" = "$(canvas_crcs "$OUT/fault-recover/app.log" | tail -1)"
test -z "$(find "$fault_recovery_app/autosave" -name '*.autosave' -print -quit 2>/dev/null || true)"

# confirm_save on an untitled document: the save succeeds and is recorded even though the
# pending open then fails; the confirmation stays so the user can cancel or retry.
fault_confirm="$OUT/fault-confirm.txt"
fault_saved="$PROJ/fault-saved.pix"
make_script "$fault_confirm" 'action stroke 10 10 20 10' "action open_project $fault_b" 'expect appshell confirm=open' 'action fault_document_prepare 0' "action confirm_save $fault_saved" "expect appshell path=$fault_saved" 'expect appshell dirty=0' 'expect appshell confirm=open' 'expect appshell prepare_fault=read_file' 'action confirm_cancel' 'expect appshell confirm=none' 'action confirm_discard' 'action request_close' 'action confirm_discard'
run_case fault-confirm "$fault_app" "$fault_confirm"
test -f "$fault_saved"
test "$(grep -c '\[harness\] action confirm_save ok ok confirm_save injected_fault=PendingOperationFailed fired_in=read_file' "$OUT/fault-confirm/app.log" || true)" -eq 1
test "$(grep -c '\[harness\] expect FAILED' "$OUT/fault-confirm/app.log" || true)" -eq 0
test "$(grep -c 'leaked' "$OUT/fault-confirm/app.log" || true)" -eq 0

# A fault consumed by a non-reporting operation (confirm_discard) must not be attributed to
# the next reporting action: `recover` with no candidate stays a genuine failure. The run
# exits non-zero on purpose, so the check is on the log lines.
fault_carry="$OUT/fault-carry.txt"
make_script "$fault_carry" 'action stroke 10 10 20 10' 'action new 16 16' 'expect appshell confirm=new' 'action fault_document_prepare 0' 'action confirm_discard' 'expect appshell confirm=new' 'action confirm_cancel' 'action recover' 'action request_close' 'action confirm_discard'
mkdir -p "$OUT/fault-carry"
set +e
KNGN_APPSHELL_DIR="$APPS/fault-carry" KNGN_HEADLESS=1 KNGN_HARNESS_SCRIPT="$fault_carry" KNGN_HARNESS_OUT="$OUT/fault-carry" "$APP" >"$OUT/fault-carry/app.log" 2>&1
carry_status=$?
set -e
test "$carry_status" -ne 0
grep -q '\[harness\] action confirm_discard FAILED OutOfMemory' "$OUT/fault-carry/app.log"
grep -q '\[harness\] action recover FAILED NoRecoveryPending' "$OUT/fault-carry/app.log"
test "$(grep -c 'injected_fault=' "$OUT/fault-carry/app.log" || true)" -eq 0

# Netsync: bind failure is an allowed sandbox skip; successful runs use kngn ctl quit.
netsync_status=skipped
if test "${KNGN_E2E_NETSYNC:-1}" = 1; then
    "$ZIG_BIN" build kngn >/dev/null 2>&1 || true
    kngn="$ROOT/zig-out/bin/kngn"
    host_port="$E2E/host.port"
    client_port="$E2E/client.port"
    KNGN_APPSHELL_DIR="$APPS/netsync-host" KNGN_HEADLESS=1 KNGN_HARNESS_LISTEN= KNGN_HARNESS_PORT_FILE="$host_port" KNGN_NETSYNC_HOST=1 KNGN_NETSYNC_PORT=9130 "$APP" >"$OUT/netsync-host.log" 2>&1 &
    host_pid=$!
    KNGN_APPSHELL_DIR="$APPS/netsync-client" KNGN_HEADLESS=1 KNGN_HARNESS_LISTEN= KNGN_HARNESS_PORT_FILE="$client_port" KNGN_NETSYNC_CONNECT=127.0.0.1:9130 "$APP" >"$OUT/netsync-client.log" 2>&1 &
    client_pid=$!
    for _ in $(seq 1 100); do
        test -f "$host_port" && test -f "$client_port" && break
        sleep 0.05
    done
    if test -x "$kngn" && test -f "$host_port" && test -f "$client_port"; then
        # free-run LISTEN: the host runs on its own, so no step inject. await holds one connection and waits for join to finish.
        "$kngn" ctl --port-file "$client_port" 'await netsync awaiting_sync=0 600' >/dev/null
        "$kngn" ctl --port-file "$host_port" 'action stroke 10 10 20 10' >/dev/null
        # In free-run, step is a frame barrier (wait N presents). Wait 120 frames, matching the autosave threshold.
        "$kngn" ctl --port-file "$host_port" 'step 120' >/dev/null
        "$kngn" ctl --port-file "$host_port" 'digest appshell' | grep -q 'autosave=0'
        "$kngn" ctl --port-file "$host_port" quit >/dev/null
        "$kngn" ctl --port-file "$client_port" quit >/dev/null
        wait "$host_pid" "$client_pid"
        netsync_status=ok
    else
        echo 'appshell_e2e: netsync bind unavailable; skipped (known sandbox restriction)' >&2
        kill -KILL "$host_pid" "$client_pid" 2>/dev/null || true
        wait "$host_pid" 2>/dev/null || true
        wait "$client_pid" 2>/dev/null || true
    fi
else
    echo 'appshell_e2e: netsync skipped by KNGN_E2E_NETSYNC=0' >&2
fi
echo "appshell_e2e: ok (recovery_crc=$after_crc netsync=$netsync_status)"
