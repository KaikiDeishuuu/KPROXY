#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_XRAY_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_XRAY_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"

ps_xray_version_string() {
  if ! ps_command_exists xray; then
    printf ""
    return 0
  fi
  xray version 2>/dev/null | head -n 1 | awk '{print $2}'
}

ps_xray_update_manifest_status() {
  local installed="false"
  local version=""
  if ps_command_exists xray; then
    installed="true"
    version="$(ps_xray_version_string)"
  fi

  ps_manifest_update \
    --argjson installed "${installed}" \
    --arg version "${version}" \
    --arg binary "$(command -v xray 2>/dev/null || printf "xray")" \
    --arg config "${PS_XRAY_CONFIG}" \
    --arg service "${PS_XRAY_SERVICE}" \
    --arg ts "$(ps_now_iso)" \
    '.engines.xray.installed = $installed | .engines.xray.version = $version | .engines.xray.binary = $binary | .engines.xray.config_path = $config | .engines.xray.service = $service | .meta.updated_at = $ts'
}

ps_xray_install_upgrade() {
  ps_print_header "Install/Upgrade xray-core"
  if ! ps_is_root; then
    ps_log_error "Root permission required for xray installation"
    return 1
  fi

  if ! ps_require_cmds curl; then
    ps_log_error "Missing required dependency"
    return 1
  fi

  if ! bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; then
    ps_log_error "xray install/upgrade failed"
    return 1
  fi

  ps_xray_update_manifest_status
  ps_log_success "xray-core installed/upgraded"
}

ps_xray_validate_config() {
  local config_path="${1:-${PS_XRAY_CONFIG}}"
  if ! ps_command_exists xray; then
    ps_log_warn "xray not installed, skip validation"
    return 0
  fi

  if xray run -test -c "${config_path}" >/dev/null 2>&1; then
    ps_log_success "xray config is valid"
    return 0
  fi

  ps_log_error "xray config validation failed: ${config_path}"
  return 1
}

ps_xray_start() {
  systemctl start "${PS_XRAY_SERVICE}"
}

ps_xray_stop() {
  systemctl stop "${PS_XRAY_SERVICE}"
}

ps_xray_restart() {
  systemctl restart "${PS_XRAY_SERVICE}"
}

ps_xray_reload() {
  systemctl reload "${PS_XRAY_SERVICE}"
}

ps_xray_show_version() {
  ps_print_header "xray-core Version"
  if ! ps_command_exists xray; then
    ps_log_warn "xray not installed"
    return 1
  fi
  xray version
}

ps_xray_uninstall() {
  ps_print_header "Uninstall xray-core"
  if ! ps_confirm "Uninstall xray-core now?" "N"; then
    ps_log_info "Cancelled"
    return 0
  fi

  if ! ps_is_root; then
    ps_log_error "Root permission required"
    return 1
  fi

  if ! bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge; then
    ps_log_error "xray uninstall failed"
    return 1
  fi

  ps_xray_update_manifest_status
  ps_log_success "xray-core removed"
}
