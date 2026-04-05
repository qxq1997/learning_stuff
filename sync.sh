#!/bin/zsh
set -euo pipefail

LOCAL="/Users/xinqi/Documents/learning_stuff"
ICLOUD="/Users/xinqi/Library/Mobile Documents/iCloud~md~obsidian/Documents/learning_stuff"
MODE="${1:-push}"
RSYNC_ARGS=(
  -rlvh
  --delete
  --exclude '.DS_Store'
  --exclude '.claude/'
  --exclude '.obsidian/'
)

if [[ ! -d "$LOCAL" ]]; then
  echo "本地目录不存在: $LOCAL" >&2
  exit 1
fi

mkdir -p "$ICLOUD"

case "$MODE" in
  push)
    echo "同步方向: 本地 -> iCloud"
    echo "同步到: $ICLOUD"
    rsync "${RSYNC_ARGS[@]}" "$LOCAL/" "$ICLOUD/"
    ;;
  pull)
    echo "同步方向: iCloud -> 本地"
    echo "回拉来源: $ICLOUD"
    rsync "${RSYNC_ARGS[@]}" "$ICLOUD/" "$LOCAL/"
    ;;
  diff)
    echo "预览差异: 本地 -> iCloud"
    echo "预览目标: $ICLOUD"
    rsync "${RSYNC_ARGS[@]}" --dry-run "$LOCAL/" "$ICLOUD/"
    ;;
  *)
    echo "用法: $0 [push|pull|diff]" >&2
    exit 1
    ;;
esac

echo "完成。"
