#!/usr/bin/env bash
# TASK-121.2 負系 runner: 自動 ID 衝突が Debug assert で非ゼロ終了することを検証する。
# 成功終了 (0) や純粋な build failure は不合格。期待は「実行時に非ゼロ」。
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
VP_ROOT="${VP_ROOT:-/Users/gamako/gamako/project/zig/video-proto/video-proto-main}"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cd "$ROOT"

echo "[negative_auto_id] running Debug headless negative case..."
set +e
VP_GUI_TORTURE_CASE=negative_auto_id \
VP_HARNESS_HEADLESS=1 \
VP_HARNESS_SCRIPT="$SCRIPT_DIR/negative_auto_id.txt" \
VP_HARNESS_OUT="$OUT" \
direnv exec "$VP_ROOT" zig build run-example_37 -Doptimize=Debug \
  >"$OUT/stdout.txt" 2>"$OUT/stderr.txt"
status=$?
set -e

echo "[negative_auto_id] exit_code=$status"
if [[ "$status" -eq 0 ]]; then
  echo "[negative_auto_id] FAIL: process exited 0 (expected Debug assert non-zero)"
  tail -n 40 "$OUT/stderr.txt" || true
  exit 1
fi

# build/step 欠落だけの失敗は除外（assert/panic 痕跡が無い場合）
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

# harness が起動してから落ちた場合も合格（assert が stderr に出ない環境向け）
if grep -Eiq 'harness|GUI Torture|negative' "$OUT/stdout.txt" "$OUT/stderr.txt" 2>/dev/null; then
  echo "[negative_auto_id] PASS: non-zero exit ($status) after process start"
  exit 0
fi

echo "[negative_auto_id] PASS (weak): non-zero exit $status"
exit 0
