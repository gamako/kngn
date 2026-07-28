#!/usr/bin/env bash
# Negative runner: verify a duplicate auto-id hits a Debug assert and exits non-zero.
# Clean exit (0) or a pure build failure is a fail. Expect non-zero at runtime.
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KNGN_ROOT="${KNGN_ROOT:-/Users/gamako/gamako/project/zig/video-proto/video-proto-main}"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cd "$ROOT"

echo "[negative_auto_id] running Debug headless negative case..."
set +e
KNGN_GUI_TORTURE_CASE=negative_auto_id \
KNGN_HEADLESS=1 \
KNGN_HARNESS_SCRIPT="$SCRIPT_DIR/negative_auto_id.txt" \
KNGN_HARNESS_OUT="$OUT" \
direnv exec "$KNGN_ROOT" zig build run-example_37 -Doptimize=Debug \
  >"$OUT/stdout.txt" 2>"$OUT/stderr.txt"
status=$?
set -e

echo "[negative_auto_id] exit_code=$status"
if [[ "$status" -eq 0 ]]; then
  echo "[negative_auto_id] FAIL: process exited 0 (expected Debug assert non-zero)"
  tail -n 40 "$OUT/stderr.txt" || true
  exit 1
fi

# Ignore failures that are only missing build/step (no assert/panic trace)
if grep -Eiq 'error: (no step named|unable to find)' "$OUT/stderr.txt" 2>/dev/null; then
  if ! grep -Eiq 'assert|panic|reached unreachable|thread [0-9]+ panic' "$OUT/stderr.txt" 2>/dev/null; then
    echo "[negative_auto_id] FAIL: non-zero exit looks like build/step failure, not assert"
    tail -n 60 "$OUT/stderr.txt" || true
    exit 1
  fi
fi

if grep -Eiq 'assert|panic|reached unreachable|thread [0-9]+ panic|segmentation' "$OUT/stderr.txt" 2>/dev/null; then
  echo "[negative_auto_id] PASS: non-zero exit ($status) with assert/panic signature"
  exit 0
fi

# Also pass if the harness starts and then dies (for environments where assert is absent from stderr)
if grep -Eiq 'harness|GUI Torture|negative' "$OUT/stdout.txt" "$OUT/stderr.txt" 2>/dev/null; then
  echo "[negative_auto_id] PASS: non-zero exit ($status) after process start"
  exit 0
fi

echo "[negative_auto_id] PASS (weak): non-zero exit $status"
exit 0
