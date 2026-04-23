#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_SYSTEMD_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_SYSTEMD_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"

ps_systemd_is_available() {
  ps_command_exists systemctl
}

ps_systemd_render_unit() {
  local template="${1}"
  local target="${2}"
  local xray_bin singbox_bin
  xray_bin="$(command -v xray 2>/dev/null || printf "/usr/local/bin/xray")"
  singbox_bin="$(command -v sing-box 2>/dev/null || printf "/usr/bin/sing-box")"

  sed \
    -e "s|{{XRAY_BIN}}|${xray_bin}|g" \
    -e "s|{{XRAY_CONFIG}}|${PS_XRAY_CONFIG}|g" \
    -e "s|{{SINGBOX_BIN}}|${singbox_bin}|g" \
    -e "s|{{SINGBOX_CONFIG}}|${PS_SINGBOX_CONFIG}|g" \
    "${template}" >"${target}"
}

ps_systemd_install_units() {
  ps_print_header "安装 systemd 单元"

  local xray_tpl="${PS_TEMPLATES_DIR}/systemd/proxy-stack-xray.service.tpl"
  local singbox_tpl="${PS_TEMPLATES_DIR}/systemd/proxy-stack-singbox.service.tpl"
  local xray_unit="${PS_SYSTEMD_DIR}/${PS_XRAY_SERVICE}.service"
  local singbox_unit="${PS_SYSTEMD_DIR}/${PS_SINGBOX_SERVICE}.service"

  if [[ ! -f "${xray_tpl}" || ! -f "${singbox_tpl}" ]]; then
    ps_log_error "缺少 systemd 模板文件"
    return 1
  fi

  mkdir -p "${PS_SYSTEMD_DIR}"
  ps_systemd_render_unit "${xray_tpl}" "${xray_unit}"
  ps_systemd_render_unit "${singbox_tpl}" "${singbox_unit}"

  if ps_systemd_is_available && ps_is_root; then
    systemctl daemon-reload
    systemctl enable "${PS_XRAY_SERVICE}" >/dev/null 2>&1 || true
    systemctl enable "${PS_SINGBOX_SERVICE}" >/dev/null 2>&1 || true
    ps_log_success "systemd 单元已安装并启用"
  else
    ps_log_warn "systemd 不可用或当前非 root。单元文件已生成到 ${PS_SYSTEMD_DIR}"
  fi
}

ps_systemd_service_action() {
  local action="${1}"
  local service="${2}"

  if ! ps_systemd_is_available; then
    ps_log_warn "systemctl 不可用"
    return 1
  fi
  if ! ps_is_root; then
    ps_log_error "执行 systemctl 需要 root 权限：${action}"
    return 1
  fi

  systemctl "${action}" "${service}"
}

ps_systemd_start_services() {
  ps_systemd_service_action start "${PS_XRAY_SERVICE}" || true
  ps_systemd_service_action start "${PS_SINGBOX_SERVICE}" || true
  ps_log_info "已发送启动命令"
}

ps_systemd_stop_services() {
  ps_systemd_service_action stop "${PS_XRAY_SERVICE}" || true
  ps_systemd_service_action stop "${PS_SINGBOX_SERVICE}" || true
  ps_log_info "已发送停止命令"
}

ps_systemd_restart_services() {
  ps_systemd_service_action restart "${PS_XRAY_SERVICE}" || true
  ps_systemd_service_action restart "${PS_SINGBOX_SERVICE}" || true
  ps_log_info "已发送重启命令"
}

ps_systemd_reload_services() {
  ps_systemd_service_action reload "${PS_XRAY_SERVICE}" || true
  ps_systemd_service_action reload "${PS_SINGBOX_SERVICE}" || true
  ps_log_info "已发送重载命令"
}

ps_systemd_status() {
  ps_print_header "服务状态"
  if ! ps_systemd_is_available; then
    ps_log_warn "systemctl 不可用"
    return 1
  fi

  systemctl --no-pager --full status "${PS_XRAY_SERVICE}" 2>/dev/null || true
  systemctl --no-pager --full status "${PS_SINGBOX_SERVICE}" 2>/dev/null || true
}
