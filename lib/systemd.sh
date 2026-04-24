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
  local xray_bin singbox_bin xray_cfg singbox_cfg
  xray_bin="$(ps_engine_binary xray)"
  singbox_bin="$(ps_engine_binary singbox)"
  xray_cfg="$(ps_engine_config_path xray)"
  singbox_cfg="$(ps_engine_config_path singbox)"

  sed \
    -e "s|{{XRAY_BIN}}|${xray_bin}|g" \
    -e "s|{{XRAY_CONFIG}}|${xray_cfg}|g" \
    -e "s|{{SINGBOX_BIN}}|${singbox_bin}|g" \
    -e "s|{{SINGBOX_CONFIG}}|${singbox_cfg}|g" \
    "${template}" >"${target}"
}

ps_systemd_service_exists() {
  local service="${1}"
  ps_systemd_is_available || return 1
  systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "${service}.service"
}

ps_systemd_active_state() {
  local service="${1}"
  ps_systemd_is_available || { printf "unknown"; return 1; }
  local state
  state="$(systemctl is-active "${service}" 2>/dev/null || true)"
  printf "%s" "${state:-inactive}"
}

ps_systemd_enabled_state() {
  local service="${1}"
  ps_systemd_is_available || { printf "unknown"; return 1; }
  local state
  state="$(systemctl is-enabled "${service}" 2>/dev/null || true)"
  printf "%s" "${state:-disabled}"
}

ps_systemd_install_units() {
  ps_print_header "安装 systemd 单元"

  local target="${1:-all}"
  local rendered=()
  mkdir -p "${PS_SYSTEMD_DIR}"

  case "${target}" in
    xray|all)
      local xray_tpl="${PS_TEMPLATES_DIR}/systemd/proxy-stack-xray.service.tpl"
      local xray_unit="${PS_SYSTEMD_DIR}/${PS_XRAY_SERVICE}.service"
      if [[ ! -f "${xray_tpl}" ]]; then
        ps_log_error "缺少 Xray systemd 模板：${xray_tpl}"
        return 1
      fi
      ps_systemd_render_unit "${xray_tpl}" "${xray_unit}"
      rendered+=("${PS_XRAY_SERVICE}")
      ;;
  esac

  case "${target}" in
    singbox|all)
      local singbox_tpl="${PS_TEMPLATES_DIR}/systemd/proxy-stack-singbox.service.tpl"
      local singbox_unit="${PS_SYSTEMD_DIR}/${PS_SINGBOX_SERVICE}.service"
      if [[ ! -f "${singbox_tpl}" ]]; then
        ps_log_error "缺少 sing-box systemd 模板：${singbox_tpl}"
        return 1
      fi
      ps_systemd_render_unit "${singbox_tpl}" "${singbox_unit}"
      rendered+=("${PS_SINGBOX_SERVICE}")
      ;;
  esac

  if [[ "${#rendered[@]}" -eq 0 ]]; then
    ps_log_error "未知 systemd 安装目标：${target}"
    return 1
  fi

  if ps_systemd_is_available && ps_is_root; then
    local service
    systemctl daemon-reload
    for service in "${rendered[@]}"; do
      systemctl enable "${service}" >/dev/null 2>&1 || true
    done
    ps_log_success "systemd 单元已安装并启用：$(IFS=,; echo "${rendered[*]}")"
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
