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
  ps_print_header "安装/升级 xray-core"
  if ! ps_is_root; then
    ps_log_error "安装 xray 需要 root 权限"
    return 1
  fi

  if ! ps_require_cmds curl; then
    ps_log_error "缺少必需依赖"
    return 1
  fi

  if ! bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; then
    ps_log_error "xray 安装/升级失败"
    return 1
  fi

  ps_xray_update_manifest_status
  ps_log_success "xray-core 已安装/升级"
}

ps_xray_validate_config() {
  local config_path="${1:-${PS_XRAY_CONFIG}}"
  if ! ps_command_exists xray; then
    ps_log_warn "xray 未安装，跳过校验"
    return 0
  fi

  if xray run -test -c "${config_path}" >/dev/null 2>&1; then
    ps_log_success "xray 配置校验通过"
    return 0
  fi

  ps_log_error "xray 配置校验失败： ${config_path}"
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
  ps_print_header "xray-core 版本"
  if ! ps_command_exists xray; then
    ps_log_warn "xray 未安装"
    return 1
  fi
  xray version
}

ps_xray_uninstall() {
  ps_print_header "卸载 xray-core"
  if ! ps_confirm "卸载 xray-core 吗？" "N"; then
    ps_log_info "已取消"
    return 0
  fi

  if ! ps_is_root; then
    ps_log_error "需要 root 权限"
    return 1
  fi

  if ! bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge; then
    ps_log_error "xray 卸载失败"
    return 1
  fi

  ps_xray_update_manifest_status
  ps_log_success "xray-core 已移除"
}
