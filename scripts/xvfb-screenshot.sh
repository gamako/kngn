#!/usr/bin/env bash
# Xvfb 上で（任意の）プログラムを動かし、画面を PNG に撮影するヘッドレス検証スクリプト。
#
# 使い方:
#   scripts/xvfb-screenshot.sh <out.png>                 # クライアント無し: root window を撮影（パイプライン疎通確認）
#   scripts/xvfb-screenshot.sh <out.png> -- <cmd> [args] # <cmd> を起動 → 数フレーム後に撮影
#
# 依存（nix devShell が供給）: Xvfb(xorg.xorgserver) / xwd(xorg.xwd) / ffmpeg
# 環境変数:
#   XVFB_DISPLAY   使用する DISPLAY（既定 :99。衝突時は別番号を指定）
#   XVFB_GEOMETRY  仮想画面サイズ（既定 1280x720x24）
#   SETTLE_SECS    クライアント起動後、撮影までの待ち秒（既定 1.5）
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
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' が PATH にありません（nix devShell 内で実行してください）" >&2; exit 1; }
done

xvfb_pid=""
cmd_pid=""
cleanup() {
  [ -n "$cmd_pid" ] && kill "$cmd_pid" 2>/dev/null || true
  [ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Xvfb 起動
Xvfb "$DISPLAY_ID" -screen 0 "$GEOMETRY" >/dev/null 2>&1 &
xvfb_pid=$!

# 表示番号を正規化（:99 / :99.0 → 99）して socket パスを組む。
display_num="${DISPLAY_ID#:}"
display_num="${display_num%%.*}"
sock="/tmp/.X11-unix/X${display_num}"

# X サーバの socket が現れるまで待つ（最大 ~5 秒）。Xvfb が落ちたら即失敗（既存 display の誤撮影を防ぐ）。
for _ in $(seq 1 50); do
  kill -0 "$xvfb_pid" 2>/dev/null || { echo "error: Xvfb ($DISPLAY_ID) が起動直後に終了しました" >&2; exit 1; }
  [ -S "$sock" ] && break
  sleep 0.1
done
[ -S "$sock" ] || { echo "error: Xvfb ($DISPLAY_ID) が起動しませんでした" >&2; exit 1; }

# クライアント指定時は起動して数フレーム待つ
if [ "${#CMD[@]}" -gt 0 ]; then
  DISPLAY="$DISPLAY_ID" "${CMD[@]}" >/dev/null 2>&1 &
  cmd_pid=$!
  sleep "$SETTLE_SECS"
  # 撮影前にクライアント生存確認（即クラッシュを「成功＋空 PNG」の false positive にしない）。
  # 短命なクライアント（一発描画して終了する類）を許容したい場合は ALLOW_CLIENT_EXIT=1。
  if ! kill -0 "$cmd_pid" 2>/dev/null; then
    rc=0
    wait "$cmd_pid" || rc=$?
    cmd_pid=""
    if [ "${ALLOW_CLIENT_EXIT:-0}" = "1" ]; then
      echo "warning: 対象コマンドは撮影前に終了しました (exit=$rc)。ALLOW_CLIENT_EXIT=1 のため続行。" >&2
    else
      # 撮影時にアプリが生きていないのは検証失敗。clean exit(0) でも early exit は失敗扱い(=1)。
      echo "error: 対象コマンドが撮影前に終了しました (exit=$rc)" >&2
      exit "$(( rc == 0 ? 1 : rc ))"
    fi
  fi
fi

# root window を xwd で取得 → ffmpeg で PNG 化
tmp_xwd="$(mktemp -t xvfb-shot.XXXXXX.xwd)"
trap 'rm -f "$tmp_xwd"; cleanup' EXIT INT TERM
xwd -root -display "$DISPLAY_ID" -out "$tmp_xwd"
# xwd の未使用バイトを alpha と誤解釈すると alpha=0 の透明 PNG になりビューアで白く見える。
# rgb24 で opaque に固定する。
ffmpeg -y -loglevel error -i "$tmp_xwd" -pix_fmt rgb24 "$OUT"

echo "screenshot -> $OUT (display=$DISPLAY_ID, geometry=$GEOMETRY)"
