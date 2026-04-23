#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_SINGBOX_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_SINGBOX_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"

ps_singbox_version_string() {
  if ! ps_command_exists sing-box; then
    printf ""
    return 0
  fi
  sing-box version 2>/dev/null | head -n 1 | awk '{print $3}'
}

ps_singbox_update_manifest_status() {
  local installed="false"
  local version=""
  if ps_command_exists sing-box; then
    installed="true"
    version="$(ps_singbox_version_string)"
  fi

  ps_manifest_update \
    --argjson installed "${installed}" \
    --arg version "${version}" \
    --arg binary "$(command -v sing-box 2>/dev/null || printf "sing-box")" \
    --arg config "${PS_SINGBOX_CONFIG}" \
    --arg service "${PS_SINGBOX_SERVICE}" \
    --arg ts "$(ps_now_iso)" \
    '.engines.singbox.installed = $installed | .engines.singbox.version = $version | .engines.singbox.binary = $binary | .engines.singbox.config_path = $config | .engines.singbox.service = $service | .meta.updated_at = $ts'
}

ps_singbox_install_upgrade() {
  ps_print_header "Install/Upgrade sing-box"
  if ! ps_is_root; then
    ps_log_error "Root permission required for sing-box installation"
    return 1
  fi

  if ps_command_exists apt-get; then
    apt-get update
    if apt-get install -y sing-box; then
      ps_singbox_update_manifest_status
      ps_log_success "sing-box installed/upgraded via apt"
      return 0
    fi
  fi

  ps_log_warn "Apt install failed or unavailable."
  ps_log_warn "TODO: Add repository bootstrap for distributions without sing-box package."
  return 1
}

ps_singbox_validate_config() {
  local config_path="${1:-${PS_SINGBOX_CONFIG}}"
  if ! ps_command_exists sing-box; then
    ps_log_warn "sing-box not installed, skip validation"
    return 0
  fi

  if sing-box check -c "${config_path}" >/dev/null 2>&1; then
    ps_log_success "sing-box config is valid"
    return 0
  fi

  ps_log_error "sing-box config validation failed: ${config_path}"
  return 1
}

ps_singbox_start() {
  systemctl start "${PS_SINGBOX_SERVICE}"
}

ps_singbox_stop() {
  systemctl stop "${PS_SINGBOX_SERVICE}"
}

ps_singbox_restart() {
  systemctl restart "${PS_SINGBOX_SERVICE}"
}

ps_singbox_reload() {
  systemctl reload "${PS_SINGBOX_SERVICE}"
}

ps_singbox_show_version() {
  ps_print_header "sing-box Version"
  if ! ps_command_exists sing-box; then
    ps_log_warn "sing-box not installed"
    return 1
  fi
  sing-box version
}

ps_singbox_uninstall() {
  ps_print_header "Uninstall sing-box"
  if ! ps_confirm "Uninstall sing-box now?" "N"; then
    ps_log_info "Cancelled"
    return 0
  fi

  if ! ps_is_root; then
    ps_log_error "Root permission required"
    return 1
  fi

  if ps_command_exists apt-get; then
    apt-get remove -y sing-box || true
    apt-get purge -y sing-box || true
  fi

  ps_singbox_update_manifest_status
  ps_log_success "sing-box uninstall completed"
}
