#!/bin/sh
# macOS 双击入口：Finder 里双击会打开终端并执行 serve.sh。
cd "$(dirname "$0")" || exit 1
exec ./serve.sh "$@"
