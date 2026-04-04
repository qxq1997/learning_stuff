#!/bin/zsh
set -euo pipefail

LOCAL="/Users/xinqi/CodeXProjects"
ICLOUD="/Users/xinqi/Library/Mobile Documents/iCloud~md~obsidian/CodeXProjects"
MODE="${1:-push}"

if [[ ! -d "$LOCAL" ]]; then
  echo "本地目录不存在: $LOCAL" >&2
  exit 1
fi

mkdir -p "$ICLOUD"

case "$MODE" in
  push)
    echo "同步方向: 本地 -> iCloud"
    rsync -avh --delete --exclude '.DS_Store' "$LOCAL/" "$ICLOUD/"
    ;;
  pull)
    echo "同步方向: iCloud -> 本地"
    rsync -avh --delete --exclude '.DS_Store' "$ICLOUD/" "$LOCAL/"
    ;;
  diff)
    echo "预览差异: 本地 -> iCloud"
    rsync -avh --delete --dry-run --exclude '.DS_Store' "$LOCAL/" "$ICLOUD/"
    ;;
  *)
    echo "用法: $0 [push|pull|diff]" >&2
    exit 1
    ;;
esac

echo "完成。"
