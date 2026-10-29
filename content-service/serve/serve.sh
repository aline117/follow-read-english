#!/usr/bin/env bash
# macOS / Linux 启动器：默认 Node，可用 --runtime 切换。
# 用法：
#   ./serve.sh                                # 默认 node
#   ./serve.sh --runtime python --port 9000
#   ./serve.sh --runtime auto                 # 有 python3 就用 Python，否则 Node
cd "$(dirname "$0")" || exit 1

runtime=node
args=()

while [ $# -gt 0 ]; do
  case "$1" in
    --runtime)
      if [ $# -lt 2 ]; then
        echo "用法：$0 [--runtime node|python|auto] [serve 参数...]" >&2
        exit 2
      fi
      runtime=$2
      shift 2
      ;;
    --runtime=*)
      runtime=${1#--runtime=}
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

case "$runtime" in
  node|python|auto) ;;
  *)
    echo "未知 runtime：$runtime（可选 node / python / auto）" >&2
    exit 2
    ;;
esac

if [ "$runtime" = "auto" ]; then
  if command -v python3 >/dev/null 2>&1; then
    runtime=python
  else
    runtime=node
  fi
fi

if [ "$runtime" = "python" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "找不到 python3；请安装 Python 3，或改用 --runtime node。" >&2
    exit 1
  fi
  exec python3 serve.py "${args[@]}"
fi

if ! command -v node >/dev/null 2>&1; then
  echo "找不到 node；请安装 Node.js，或改用 --runtime python。" >&2
  exit 1
fi
exec node serve.js "${args[@]}"
