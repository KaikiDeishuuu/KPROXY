#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${SCRIPT_DIR}/install.sh" ]]; then
  printf "ERROR: install.sh was not found next to forward.sh\n" >&2
  printf "Run from a full repository checkout or use the remote bootstrap path documented in README.\n" >&2
  exit 2
fi

exec bash "${SCRIPT_DIR}/install.sh" --mode forward "$@"
