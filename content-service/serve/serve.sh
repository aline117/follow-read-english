#!/bin/sh
# macOS / Linux 启动脚本：优先用 Python（系统自带），没有 Python 再用 Node。
# 用法：./serve.sh [--port 9000] [--root /path/to/content-service]
cd "$(dirname "$0")" || exit 1

if command -v python3 >/dev/null 2>&1; then
  exec python3 serve.py "$@"
fi

if command -v node >/dev/null 2>&1; then
  exec node serve.js "$@"
fi

echo "找不到 python3 或 node，请先安装其中一个。" >&2
exit 1
