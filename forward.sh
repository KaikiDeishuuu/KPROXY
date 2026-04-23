#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${SCRIPT_DIR}/install.sh" ]]; then
  printf '%s\n' "错误：未在 forward.sh 同目录找到 install.sh" >&2
  printf '%s\n' "请在完整仓库目录运行，或按 README 使用远程引导安装方式。" >&2
  exit 2
fi

exec bash "${SCRIPT_DIR}/install.sh" --mode forward "$@"
