#!/usr/bin/env bash
# headless Wayland compositor 上で（任意の）プログラムを動かし、画面を PNG に撮影する検証スクリプト。
# X11 版 scripts/xvfb-screenshot.sh の Wayland 対応版（TASK-28.5.5）。
#
# 使い方:
#   scripts/wayland-screenshot.sh <out.png>                 # クライアント無し: compositor 出力を撮影（疎通確認）
#   scripts/wayland-screenshot.sh <out.png> -- <cmd> [args] # <cmd> を起動 → 数フレーム後に撮影
#
# 依存（nix devShell が供給）:
#   - sway 経路（既定）: sway(WLR_BACKENDS=headless) + grim
#   - weston 経路       : weston(headless backend) + weston-screenshooter
# 環境変数:
#   WAYLAND_SHOT_COMPOSITOR  sway | weston（既定 sway）
#   WAYLAND_SHOT_DISPLAY     weston の socket 名（既定 wayland-vp。sway は自動採番を検出）
#   WAYLAND_SHOT_GEOMETRY    WxH（既定 1280x720）
#   COMPOSITOR_SETTLE_SECS   socket 出現後、output 準備を待つ秒（既定 0.5。headless の output 反映遅れ対策）
#   SETTLE_SECS              クライアント起動後、撮影までの待ち秒（既定 1.5）
#   ALLOW_CLIENT_EXIT        1 なら、撮影前にクライアントが終了しても続行（既定 0=失敗扱い）
#
# 注: headless compositor の起動法・出力名・screenshooter の権限は実機（Linux）依存のため、
# 実起動・撮影は Linux 実機で検証して調整する。macOS では実行できない（bash -n の構文確認のみ可）。
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

# compositor ごとに必要ツールを確認。
case "$COMPOSITOR" in
  sway)   tools=(sway grim) ;;
  weston) tools=(weston weston-screenshooter) ;;
  *) echo "error: WAYLAND_SHOT_COMPOSITOR は sway か weston（指定: $COMPOSITOR）" >&2; exit 2 ;;
esac
for tool in "${tools[@]}"; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' が PATH にありません（nix devShell 内で実行してください）" >&2; exit 1; }
done

# 既存 session と衝突しないよう専用の XDG_RUNTIME_DIR に socket を作る。
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

# compositor を headless 起動し、WAYLAND_DISPLAY を確定する。
if [ "$COMPOSITOR" = "sway" ]; then
  # sway は config 必須。最小構成（headless 出力の解像度のみ）。実機で出力名/起動法は要調整。
  sway_config="$(mktemp -t wl-shot-sway.XXXXXX.conf)"
  printf 'output HEADLESS-1 resolution %sx%s\n' "$W" "$H" > "$sway_config"
  WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 sway -c "$sway_config" >/dev/null 2>&1 &
  comp_pid=$!
  # wlroots は XDG_RUNTIME_DIR に wayland-N socket を自動採番で作る。現れたものを採用。
  WAYLAND_DISPLAY=""
  for _ in $(seq 1 100); do
    kill -0 "$comp_pid" 2>/dev/null || { echo "error: sway (headless) が起動直後に終了しました" >&2; exit 1; }
    sock="$(ls "$runtime_dir"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -n1 || true)"
    [ -n "$sock" ] && [ -S "$sock" ] && { WAYLAND_DISPLAY="$(basename "$sock")"; break; }
    sleep 0.1
  done
else
  WAYLAND_DISPLAY="${WAYLAND_SHOT_DISPLAY:-wayland-vp}"
  weston --backend=headless-backend.so --socket="$WAYLAND_DISPLAY" --width="$W" --height="$H" >/dev/null 2>&1 &
  comp_pid=$!
  for _ in $(seq 1 100); do
    kill -0 "$comp_pid" 2>/dev/null || { echo "error: weston (headless) が起動直後に終了しました" >&2; exit 1; }
    [ -S "$runtime_dir/$WAYLAND_DISPLAY" ] && break
    sleep 0.1
  done
fi

if [ -z "${WAYLAND_DISPLAY:-}" ] || [ ! -S "$runtime_dir/$WAYLAND_DISPLAY" ]; then
  echo "error: $COMPOSITOR の Wayland socket が現れませんでした（headless 起動可否を Linux 実機で確認）" >&2
  exit 1
fi
export WAYLAND_DISPLAY

# socket 出現直後は output 生成・設定反映が未完のことがある（headless）。短く待ってから描画/撮影する。
sleep "${COMPOSITOR_SETTLE_SECS:-0.5}"

# クライアント指定時は起動して数フレーム待つ。
if [ "${#CMD[@]}" -gt 0 ]; then
  "${CMD[@]}" >/dev/null 2>&1 &
  cmd_pid=$!
  sleep "$SETTLE_SECS"
  # 撮影前にクライアント生存確認（即クラッシュを「成功＋空 PNG」の false positive にしない）。
  if ! kill -0 "$cmd_pid" 2>/dev/null; then
    rc=0
    wait "$cmd_pid" || rc=$?
    cmd_pid=""
    if [ "${ALLOW_CLIENT_EXIT:-0}" = "1" ]; then
      echo "warning: 対象コマンドは撮影前に終了しました (exit=$rc)。ALLOW_CLIENT_EXIT=1 のため続行。" >&2
    else
      echo "error: 対象コマンドが撮影前に終了しました (exit=$rc)" >&2
      exit "$(( rc == 0 ? 1 : rc ))"
    fi
  fi
fi

# screenshot を撮る（compositor により手段が異なる）。
if [ "$COMPOSITOR" = "sway" ]; then
  grim "$OUT"
else
  # weston-screenshooter は既定で cwd に時刻付きファイルを保存するため、tmp cwd で撮って $OUT へ移す。
  # shot_dir は cleanup trap が削除する（失敗・mv 失敗・set -e exit でも残らない）。
  shot_dir="$(mktemp -d -t wl-shot-out.XXXXXX)"
  ( cd "$shot_dir" && weston-screenshooter )
  produced="$(ls "$shot_dir"/*.png 2>/dev/null | head -n1 || true)"
  if [ -z "$produced" ]; then
    echo "error: weston-screenshooter が PNG を生成しませんでした" >&2
    exit 1
  fi
  mv "$produced" "$OUT"
fi

echo "screenshot -> $OUT (compositor=$COMPOSITOR, display=$WAYLAND_DISPLAY, geometry=${W}x${H})"
