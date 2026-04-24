#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_LOGGER_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_LOGGER_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

ps_level_to_int() {
  case "${1:-info}" in
    debug) printf "10" ;;
    info) printf "20" ;;
    warn) printf "30" ;;
    error) printf "40" ;;
    *) printf "20" ;;
  esac
}

ps_logger_init() {
  ps_prepare_runtime_dirs
  mkdir -p "$(dirname "${PS_INSTALL_LOG}")"
  touch "${PS_INSTALL_LOG}"
}

ps_current_log_level() {
  local level="info"
  if [[ -f "${PS_MANIFEST}" ]]; then
    level="$(jq -r '.logs.level // "info"' "${PS_MANIFEST}" 2>/dev/null || printf "info")"
  fi
  printf "%s" "${level}"
}

ps_log() {
  local level="${1:-info}"
  shift || true
  local message="${*:-}"
  local now
  now="$(date +"%Y-%m-%d %H:%M:%S")"

  local current_level
  current_level="$(ps_current_log_level)"
  if (( $(ps_level_to_int "${level}") < $(ps_level_to_int "${current_level}") )); then
    return 0
  fi

  local line="[${now}] [${level^^}] ${message}"
  printf "%s\n" "${line}"
  mkdir -p "$(dirname "${PS_INSTALL_LOG}")" 2>/dev/null || true
  touch "${PS_INSTALL_LOG}" 2>/dev/null || true
  printf "%s\n" "${line}" >>"${PS_INSTALL_LOG}" 2>/dev/null || true
}

ps_log_debug() { ps_log debug "$*"; }
ps_log_info() { ps_log info "$*"; }
ps_log_warn() { ps_log warn "$*"; }
ps_log_error() { ps_log error "$*"; }
ps_log_success() { ps_log info "成功：$*"; }

ps_tail_file() {
  local file_path="${1:-}"
  if [[ ! -f "${file_path}" ]]; then
    ps_log_warn "日志文件不存在： ${file_path}"
    return 1
  fi
  tail -n 50 -f "${file_path}"
}
