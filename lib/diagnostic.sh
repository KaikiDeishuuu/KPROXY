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
  ps_print_header "Installation Log"
  if [[ -f "${PS_INSTALL_LOG}" ]]; then
    tail -n 200 "${PS_INSTALL_LOG}"
  else
    ps_log_warn "Install log not found: ${PS_INSTALL_LOG}"
  fi
}

ps_diag_view_xray_service_log() {
  ps_print_header "Xray Service Log"
  if ps_command_exists journalctl; then
    journalctl -u "${PS_XRAY_SERVICE}" -n 200 --no-pager 2>/dev/null || true
  else
    ps_log_warn "journalctl unavailable"
  fi
}

ps_diag_view_singbox_service_log() {
  ps_print_header "sing-box Service Log"
  if ps_command_exists journalctl; then
    journalctl -u "${PS_SINGBOX_SERVICE}" -n 200 --no-pager 2>/dev/null || true
  else
    ps_log_warn "journalctl unavailable"
  fi
}

ps_diag_view_access_log() {
  ps_print_header "Xray Access Log"
  local file_path
  file_path="$(ps_diag_log_path xray_access)"
  if [[ -f "${file_path}" ]]; then
    tail -n 200 "${file_path}"
  else
    ps_log_warn "Access log not found: ${file_path}"
  fi
}

ps_diag_view_error_log() {
  ps_print_header "Xray Error Log"
  local file_path
  file_path="$(ps_diag_log_path xray_error)"
  if [[ -f "${file_path}" ]]; then
    tail -n 200 "${file_path}"
  else
    ps_log_warn "Error log not found: ${file_path}"
  fi
}

ps_diag_change_log_level() {
  ps_print_header "Change Log Level"
  printf "1) debug\n2) info\n3) warn\n4) error\n"
  local level
  case "$(ps_prompt_required "Level number")" in
    1) level="debug" ;;
    2) level="info" ;;
    3) level="warn" ;;
    4) level="error" ;;
    *) ps_log_error "Invalid level"; return 1 ;;
  esac

  ps_manifest_update --arg level "${level}" --arg ts "$(ps_now_iso)" '.logs.level = $level | .meta.updated_at = $ts'
  ps_log_success "Log level updated: ${level}"
}

ps_diag_toggle_dns_logging() {
  ps_print_header "Toggle DNS Logging"
  local current next
  current="$(jq -r '.logs.dns_log // false' "${PS_MANIFEST}")"
  next="true"
  [[ "${current}" == "true" ]] && next="false"

  ps_manifest_update --argjson dns "${next}" --arg ts "$(ps_now_iso)" '.logs.dns_log = $dns | .meta.updated_at = $ts'
  ps_log_success "DNS logging switched to ${next}"
}

ps_diag_configure_log_rotation() {
  ps_print_header "Configure Log Rotation"
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
    printf "%s\n" "${config_content}" >/etc/logrotate.d/proxy-stack
    ps_log_success "Logrotate config written: /etc/logrotate.d/proxy-stack"
  else
    local local_file="${PS_ROOT_DIR}/.runtime/logrotate-proxy-stack.conf"
    mkdir -p "$(dirname "${local_file}")"
    printf "%s\n" "${config_content}" >"${local_file}"
    ps_log_warn "Non-root mode, wrote local logrotate sample: ${local_file}"
  fi
}

ps_diag_tail_logs() {
  ps_print_header "Tail Logs in Real Time"
  printf "1) install log\n"
  printf "2) xray access log\n"
  printf "3) xray error log\n"
  printf "4) sing-box log\n"

  local file_path
  case "$(ps_prompt_required "Log number")" in
    1) file_path="${PS_INSTALL_LOG}" ;;
    2) file_path="$(ps_diag_log_path xray_access)" ;;
    3) file_path="$(ps_diag_log_path xray_error)" ;;
    4) file_path="$(ps_diag_log_path singbox_log)" ;;
    *) ps_log_error "Invalid selection"; return 1 ;;
  esac

  if [[ ! -f "${file_path}" ]]; then
    ps_log_error "Log file not found: ${file_path}"
    return 1
  fi

  tail -n 100 -f "${file_path}"
}

ps_diag_export_bundle() {
  ps_print_header "Export Diagnostic Bundle"
  mkdir -p "${PS_OUTPUT_DIR}"

  local tmpdir bundle_file ts
  ts="$(ps_now_compact)"
  tmpdir="$(mktemp -d)"
  bundle_file="${PS_OUTPUT_DIR}/diagnostic-${ts}.tar.gz"

  jq '{meta, engines, logs, certificates, stack_count:(.stacks|length), inbound_count:(.inbounds|length), outbound_count:(.outbounds|length), route_count:(.routes|length)}' "${PS_MANIFEST}" >"${tmpdir}/manifest-summary.json"
  cp -a "${PS_MANIFEST}" "${tmpdir}/manifest-full.json"

  {
    printf "xray: "
    xray version 2>/dev/null | head -n 1 || printf "not installed\n"
    printf "sing-box: "
    sing-box version 2>/dev/null | head -n 1 || printf "not installed\n"
  } >"${tmpdir}/engine-versions.txt"

  if ps_command_exists systemctl; then
    systemctl status "${PS_XRAY_SERVICE}" >"${tmpdir}/systemd-xray-status.txt" 2>&1 || true
    systemctl status "${PS_SINGBOX_SERVICE}" >"${tmpdir}/systemd-singbox-status.txt" 2>&1 || true
  else
    printf "systemctl unavailable\n" >"${tmpdir}/systemd-xray-status.txt"
    printf "systemctl unavailable\n" >"${tmpdir}/systemd-singbox-status.txt"
  fi

  if [[ -f "${PS_INSTALL_LOG}" ]]; then tail -n 200 "${PS_INSTALL_LOG}" >"${tmpdir}/install-log-tail.txt"; fi
  local xray_access xray_error singbox_log
  xray_access="$(ps_diag_log_path xray_access)"
  xray_error="$(ps_diag_log_path xray_error)"
  singbox_log="$(ps_diag_log_path singbox_log)"
  [[ -f "${xray_access}" ]] && tail -n 200 "${xray_access}" >"${tmpdir}/xray-access-tail.txt"
  [[ -f "${xray_error}" ]] && tail -n 200 "${xray_error}" >"${tmpdir}/xray-error-tail.txt"
  [[ -f "${singbox_log}" ]] && tail -n 200 "${singbox_log}" >"${tmpdir}/singbox-tail.txt"

  ss -lntup >"${tmpdir}/listening-ports.txt" 2>/dev/null || printf "ss command unavailable\n" >"${tmpdir}/listening-ports.txt"

  jq '.stacks | map(select(.enabled == true) | {stack_id,name,engine,protocol,security,transport,server,port})' "${PS_MANIFEST}" >"${tmpdir}/active-stacks.json"
  jq '.routes | sort_by(.priority) | map(select(.enabled != false) | {name,priority,outbound,inbound_tag,domain_suffix,domain_keyword,ip_cidr,network})' "${PS_MANIFEST}" >"${tmpdir}/active-routes.json"

  tar -czf "${bundle_file}" -C "${tmpdir}" .
  rm -rf "${tmpdir}"

  ps_log_success "Diagnostic bundle exported: ${bundle_file}"
}
