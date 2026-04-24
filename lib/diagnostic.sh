#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_DIAGNOSTIC_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_DIAGNOSTIC_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"

ps_diag_log_path() {
  local key="${1}"
  jq -r --arg k "${key}" '.logs[$k] // ""' "${PS_MANIFEST}"
}

ps_diag_view_install_log() {
  ps_print_header "安装日志"
  if [[ -f "${PS_INSTALL_LOG}" ]]; then
    tail -n 200 "${PS_INSTALL_LOG}"
  else
    ps_log_warn "安装日志不存在：${PS_INSTALL_LOG}"
  fi
}

ps_diag_view_xray_service_log() {
  ps_print_header "Xray 服务日志"
  if ps_command_exists journalctl; then
    journalctl -u "${PS_XRAY_SERVICE}" -n 200 --no-pager 2>/dev/null || true
  else
    ps_log_warn "journalctl 不可用"
  fi
}

ps_diag_view_singbox_service_log() {
  ps_print_header "sing-box 服务日志"
  if ps_command_exists journalctl; then
    journalctl -u "${PS_SINGBOX_SERVICE}" -n 200 --no-pager 2>/dev/null || true
  else
    ps_log_warn "journalctl 不可用"
  fi
}

ps_diag_view_access_log() {
  ps_print_header "Xray 访问日志"
  local file_path
  file_path="$(ps_diag_log_path xray_access)"
  if [[ -f "${file_path}" ]]; then
    tail -n 200 "${file_path}"
  else
    ps_log_warn "访问日志不存在：${file_path}"
  fi
}

ps_diag_view_error_log() {
  ps_print_header "Xray 错误日志"
  local file_path
  file_path="$(ps_diag_log_path xray_error)"
  if [[ -f "${file_path}" ]]; then
    tail -n 200 "${file_path}"
  else
    ps_log_warn "错误日志不存在：${file_path}"
  fi
}

ps_diag_change_log_level() {
  ps_print_header "调整日志级别"
  printf "1) debug\n2) info\n3) warn\n4) error\n"
  local level
  case "$(ps_prompt_required "级别编号")" in
    1) level="debug" ;;
    2) level="info" ;;
    3) level="warn" ;;
    4) level="error" ;;
    *) ps_log_error "日志级别无效"; return 1 ;;
  esac

  ps_manifest_update --arg level "${level}" --arg ts "$(ps_now_iso)" '.logs.level = $level | .meta.updated_at = $ts'
  ps_log_success "日志级别已更新： ${level}"
}

ps_diag_toggle_dns_logging() {
  ps_print_header "切换 DNS 日志"
  local current next
  current="$(jq -r '.logs.dns_log // false' "${PS_MANIFEST}")"
  next="true"
  [[ "${current}" == "true" ]] && next="false"

  ps_manifest_update --argjson dns "${next}" --arg ts "$(ps_now_iso)" '.logs.dns_log = $dns | .meta.updated_at = $ts'
  ps_log_success "DNS 日志已切换为 ${next}"
}

ps_diag_configure_log_rotation() {
  ps_print_header "配置日志轮转"
  local config_content
  config_content="${PS_LOG_DIR}/*.log {
  daily
  rotate 14
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
}"

  if ps_is_root; then
    printf "%s\n" "${config_content}" >/etc/logrotate.d/kprxy
    ps_log_success "Logrotate 配置已写入： /etc/logrotate.d/kprxy"
  else
    local local_file="${PS_ROOT_DIR}/.runtime/logrotate-kprxy.conf"
    mkdir -p "$(dirname "${local_file}")"
    printf "%s\n" "${config_content}" >"${local_file}"
    ps_log_warn "非 root 模式：已写入本地 logrotate 样例：${local_file}"
  fi
}

ps_diag_tail_logs() {
  ps_print_header "实时跟踪日志"
  printf "1) 安装日志\n"
  printf "2) xray 访问日志\n"
  printf "3) xray 错误日志\n"
  printf "4) sing-box 日志\n"

  local file_path
  case "$(ps_prompt_required "日志编号")" in
    1) file_path="${PS_INSTALL_LOG}" ;;
    2) file_path="$(ps_diag_log_path xray_access)" ;;
    3) file_path="$(ps_diag_log_path xray_error)" ;;
    4) file_path="$(ps_diag_log_path singbox_log)" ;;
    *) ps_log_error "选择无效"; return 1 ;;
  esac

  if [[ ! -f "${file_path}" ]]; then
    ps_log_error "日志文件不存在： ${file_path}"
    return 1
  fi

  tail -n 100 -f "${file_path}"
}

ps_diag_export_bundle() {
  ps_print_header "导出诊断包"
  mkdir -p "${PS_OUTPUT_DIR}"

  local tmpdir bundle_file ts
  ts="$(ps_now_compact)"
  tmpdir="$(mktemp -d)"
  bundle_file="${PS_OUTPUT_DIR}/diagnostic-${ts}.tar.gz"

  jq '{meta, engines, logs, certificates, stack_count:(.stacks|length), inbound_count:(.inbounds|length), outbound_count:(.outbounds|length), route_count:(.routes|length)}' "${PS_MANIFEST}" >"${tmpdir}/manifest-summary.json"
  cp -a "${PS_MANIFEST}" "${tmpdir}/manifest-full.json"

  {
    printf "xray: "
    if [[ -x "$(ps_engine_binary xray)" ]]; then
      "$(ps_engine_binary xray)" version 2>/dev/null | head -n 1 || printf "未安装\n"
    else
      printf "未安装\n"
    fi
    printf "sing-box: "
    if [[ -x "$(ps_engine_binary singbox)" ]]; then
      "$(ps_engine_binary singbox)" version 2>/dev/null | head -n 1 || printf "未安装\n"
    else
      printf "未安装\n"
    fi
  } >"${tmpdir}/engine-versions.txt"

  if ps_command_exists systemctl; then
    systemctl status "${PS_XRAY_SERVICE}" >"${tmpdir}/systemd-xray-status.txt" 2>&1 || true
    systemctl status "${PS_SINGBOX_SERVICE}" >"${tmpdir}/systemd-singbox-status.txt" 2>&1 || true
  else
    printf "systemctl 不可用\n" >"${tmpdir}/systemd-xray-status.txt"
    printf "systemctl 不可用\n" >"${tmpdir}/systemd-singbox-status.txt"
  fi

  if [[ -f "${PS_INSTALL_LOG}" ]]; then tail -n 200 "${PS_INSTALL_LOG}" >"${tmpdir}/install-log-tail.txt"; fi
  local xray_access xray_error singbox_log
  xray_access="$(ps_diag_log_path xray_access)"
  xray_error="$(ps_diag_log_path xray_error)"
  singbox_log="$(ps_diag_log_path singbox_log)"
  [[ -f "${xray_access}" ]] && tail -n 200 "${xray_access}" >"${tmpdir}/xray-access-tail.txt"
  [[ -f "${xray_error}" ]] && tail -n 200 "${xray_error}" >"${tmpdir}/xray-error-tail.txt"
  [[ -f "${singbox_log}" ]] && tail -n 200 "${singbox_log}" >"${tmpdir}/singbox-tail.txt"

  ss -lntup >"${tmpdir}/listening-ports.txt" 2>/dev/null || printf "ss 命令不可用\n" >"${tmpdir}/listening-ports.txt"

  jq '.stacks | map(select(.enabled == true) | {stack_id,name,engine,protocol,security,transport,server,port})' "${PS_MANIFEST}" >"${tmpdir}/active-stacks.json"
  jq '.routes | sort_by(.priority) | map(select(.enabled != false) | {name,priority,outbound,inbound_tag,domain_suffix,domain_keyword,ip_cidr,network})' "${PS_MANIFEST}" >"${tmpdir}/active-routes.json"

  tar -czf "${bundle_file}" -C "${tmpdir}" .
  rm -rf "${tmpdir}"

  ps_log_success "诊断包已导出： ${bundle_file}"
}
