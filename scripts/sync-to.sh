#!/usr/bin/env bash
# sync-to.sh -- video-proto-main/ のソースを Linux 検証機へ rsync 転送する
#
# jackjack / shiso は jj/git の remote を持たないため、Mac から rsync でソース実体を
# 送って現地でネイティブビルドする（詳細は memory: jackjack/shiso の検証メモ参照）。
#
# 使い方:
#   bash scripts/sync-to.sh <host>        # 転送を実行
#   bash scripts/sync-to.sh -n <host>     # dry-run（何が送られ/消えるか確認のみ）
#
#   <host> は ssh で解決できるホスト名（例: jackjack / shiso）。
#
# 転送先は常に <host>:~/video-proto-main/。--delete でソース構成にミラーするが、
# 除外した .zig-cache / zig-out は対象外なので現地のビルドキャッシュは保持される。
set -euo pipefail

usage() {
  echo "usage: bash scripts/sync-to.sh [-n] <host>" >&2
  echo "  -n   dry-run（実際には転送せず差分のみ表示）" >&2
}

DRY_RUN=""
while getopts "nh" opt; do
  case "${opt}" in
    n) DRY_RUN="--dry-run" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

HOST="${1:-}"
if [[ -z "${HOST}" ]]; then
  usage
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEST="${HOST}:~/video-proto-main/"

if [[ -n "${DRY_RUN}" ]]; then
  echo "[sync-to] DRY-RUN: ${REPO_ROOT}/ -> ${DEST}"
else
  echo "[sync-to] sync: ${REPO_ROOT}/ -> ${DEST}"
fi

rsync -avz --delete ${DRY_RUN} \
  --exclude='.zig-cache' \
  --exclude='zig-out' \
  --exclude='.git' \
  --exclude='.jj' \
  --exclude='.DS_Store' \
  "${REPO_ROOT}/" "${DEST}"
