#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_UNINSTALL_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_UNINSTALL_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"
# shellcheck source=lib/systemd.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/systemd.sh"

PS_LIFECYCLE_REMOVED=()
PS_LIFECYCLE_PRESERVED=()
PS_LIFECYCLE_SKIPPED=()
PS_LIFECYCLE_ASSUME_YES="${PS_LIFECYCLE_ASSUME_YES:-0}"

ps_lifecycle_record_removed() {
  local item="${1:-}"
  [[ -n "${item}" ]] || return 0
  PS_LIFECYCLE_REMOVED+=("${item}")
  ps_log_info "已删除：${item}"
}

ps_lifecycle_record_preserved() {
  local item="${1:-}"
  [[ -n "${item}" ]] || return 0
  PS_LIFECYCLE_PRESERVED+=("${item}")
  ps_log_info "已保留：${item}"
}

ps_lifecycle_record_skipped() {
  local item="${1:-}"
  [[ -n "${item}" ]] || return 0
  PS_LIFECYCLE_SKIPPED+=("${item}")
  ps_log_warn "跳过：${item}"
}

ps_lifecycle_confirm() {
  local message="${1:-确认执行吗？}"
  local default_choice="${2:-N}"
  if [[ "${PS_LIFECYCLE_ASSUME_YES}" == "1" ]]; then
    ps_log_warn "已启用 --yes，自动确认：${message}"
    return 0
  fi
  ps_confirm "${message}" "${default_choice}"
}

ps_lifecycle_is_safe_owned_path() {
  local target="${1:-}"
  [[ -n "${target}" ]] || return 1

  case "${target}" in
    /opt/kprxy|/opt/kprxy/*) return 0 ;;
    /usr/local/share/kprxy|/usr/local/share/kprxy/*) return 0 ;;
    "${HOME}/.local/share/kprxy"|"${HOME}/.local/share/kprxy"/*) return 0 ;;
    "${PS_ROOT_DIR}/.runtime"|"${PS_ROOT_DIR}/.runtime"/*) return 0 ;;
    "${PS_ROOT_DIR}/output"|"${PS_ROOT_DIR}/output"/*) return 0 ;;
    "${PS_ROOT_DIR}/backups"|"${PS_ROOT_DIR}/backups"/*) return 0 ;;
    "${PS_ROOT_DIR}/state"|"${PS_ROOT_DIR}/state"/*) return 0 ;;
    "${HOME}/.local/bin/kprxy") return 0 ;;
    /usr/local/bin/kprxy) return 0 ;;
    /etc/systemd/system/kprxy-xray.service|/etc/systemd/system/kprxy-singbox.service) return 0 ;;
    /etc/cron.d/kprxy-acme|/etc/cron.d/proxy-stack-acme) return 0 ;;
    *) return 1 ;;
  esac
}

ps_lifecycle_safe_remove_file() {
  local file_path="${1:-}"
  [[ -n "${file_path}" ]] || return 0

  if [[ ! -e "${file_path}" ]]; then
    ps_lifecycle_record_skipped "文件不存在：${file_path}"
    return 0
  fi

  if ! ps_lifecycle_is_safe_owned_path "${file_path}"; then
    ps_lifecycle_record_skipped "归属不明确，未删除：${file_path}"
    return 0
  fi

  if rm -f "${file_path}" 2>/dev/null; then
    ps_lifecycle_record_removed "文件 ${file_path}"
  else
    ps_lifecycle_record_skipped "删除失败（权限或锁定）：${file_path}"
  fi
}

ps_lifecycle_safe_remove_dir() {
  local dir_path="${1:-}"
  [[ -n "${dir_path}" ]] || return 0

  if [[ ! -e "${dir_path}" ]]; then
    ps_lifecycle_record_skipped "目录不存在：${dir_path}"
    return 0
  fi

  if ! ps_lifecycle_is_safe_owned_path "${dir_path}"; then
    ps_lifecycle_record_skipped "归属不明确，未删除：${dir_path}"
    return 0
  fi

  if rm -rf "${dir_path}" 2>/dev/null; then
    ps_lifecycle_record_removed "目录 ${dir_path}"
  else
    ps_lifecycle_record_skipped "删除失败（权限或锁定）：${dir_path}"
  fi
}

ps_lifecycle_launcher_candidates() {
  local candidates=()

  if [[ -n "${PS_BOOTSTRAP_LAUNCHER_PATH:-}" ]]; then
    candidates+=("${PS_BOOTSTRAP_LAUNCHER_PATH}")
  fi
  candidates+=("/usr/local/bin/kprxy")
  candidates+=("${HOME}/.local/bin/kprxy")

  printf '%s\n' "${candidates[@]}" | awk '!seen[$0]++'
}

ps_lifecycle_is_kprxy_launcher() {
  local launcher_path="${1:-}"
  [[ -f "${launcher_path}" ]] || return 1

  if ! grep -Fq 'exec bash "' "${launcher_path}"; then
    return 1
  fi
  if ! grep -Eq '/kprxy/.*/install\.sh|/kprxy/install\.sh' "${launcher_path}"; then
    return 1
  fi

  return 0
}

ps_lifecycle_remove_launcher() {
  local removed_any=0
  local launcher
  while read -r launcher; do
    [[ -n "${launcher}" ]] || continue
    if [[ ! -e "${launcher}" ]]; then
      ps_lifecycle_record_skipped "启动器不存在：${launcher}"
      continue
    fi

    if ps_lifecycle_is_kprxy_launcher "${launcher}"; then
      ps_lifecycle_safe_remove_file "${launcher}"
      removed_any=1
    else
      ps_lifecycle_record_skipped "启动器归属不明确，未删除：${launcher}"
    fi
  done < <(ps_lifecycle_launcher_candidates)

  if [[ "${removed_any}" -eq 0 ]]; then
    ps_log_info "未删除任何启动器。"
  fi
}

ps_lifecycle_manage_service() {
  local service="${1:-}"
  [[ -n "${service}" ]] || return 0

  local unit_in_etc="/etc/systemd/system/${service}.service"
  local unit_in_runtime="${PS_SYSTEMD_DIR}/${service}.service"
  local service_owned="1"

  if [[ ! "${service}" =~ ^kprxy-(xray|singbox)$ ]]; then
    ps_lifecycle_record_skipped "服务名不属于 kprxy，未处理：${service}.service"
    return 0
  fi

  if [[ -f "${unit_in_etc}" ]] && ! grep -Eiq 'kprxy|/opt/kprxy|/kprxy/' "${unit_in_etc}"; then
    service_owned="0"
    ps_lifecycle_record_skipped "服务文件归属不明确，未处理：${unit_in_etc}"
  fi

  if [[ "${service_owned}" == "1" ]]; then
    if ps_systemd_is_available && ps_is_root; then
      systemctl stop "${service}" >/dev/null 2>&1 || true
      systemctl disable "${service}" >/dev/null 2>&1 || true
      ps_log_info "已执行 stop/disable：${service}.service"
    elif ps_systemd_is_available && ! ps_is_root; then
      ps_lifecycle_record_skipped "非 root，无法 stop/disable：${service}.service"
    fi
  fi

  if [[ "${service_owned}" == "1" && -f "${unit_in_etc}" ]]; then
    ps_lifecycle_safe_remove_file "${unit_in_etc}"
  elif [[ ! -f "${unit_in_etc}" ]]; then
    ps_lifecycle_record_skipped "服务文件不存在：${unit_in_etc}"
  fi

  if [[ "${service_owned}" == "1" && -f "${unit_in_runtime}" ]]; then
    ps_lifecycle_safe_remove_file "${unit_in_runtime}"
  fi
}

ps_lifecycle_remove_services() {
  ps_lifecycle_manage_service "${PS_XRAY_SERVICE}"
  ps_lifecycle_manage_service "${PS_SINGBOX_SERVICE}"

  if ps_systemd_is_available && ps_is_root; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    ps_log_info "已执行 systemctl daemon-reload"
  fi
}

ps_lifecycle_remove_cron_entries() {
  local cron_file
  for cron_file in /etc/cron.d/kprxy-acme /etc/cron.d/proxy-stack-acme; do
    if [[ -f "${cron_file}" ]]; then
      ps_lifecycle_safe_remove_file "${cron_file}"
    fi
  done
}

ps_lifecycle_cleanup_transient() {
  ps_print_header "清理临时文件"
  ps_log_info "模式：cleanup"

  local transient_paths=(
    "${PS_ROOT_DIR}/.runtime"
    "${PS_OUTPUT_DIR}"
    "${PS_BACKUP_DIR}"
  )

  local p
  for p in "${transient_paths[@]}"; do
    if [[ -d "${p}" ]]; then
      if find "${p}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; then
        ps_lifecycle_record_removed "清理目录内容 ${p}/*"
      else
        ps_lifecycle_record_skipped "清理失败（权限不足）：${p}"
      fi
    else
      ps_lifecycle_record_skipped "目录不存在：${p}"
    fi
  done

  local cfg_dir
  for cfg_dir in "$(dirname "${PS_XRAY_CONFIG}")" "$(dirname "${PS_SINGBOX_CONFIG}")"; do
    if [[ -d "${cfg_dir}" ]]; then
      if find "${cfg_dir}" -type f \( -name '*.tmp' -o -name '*.bak' -o -name '*.test.json' \) -delete 2>/dev/null; then
        ps_lifecycle_record_removed "清理临时配置：${cfg_dir}"
      else
        ps_lifecycle_record_skipped "清理临时配置失败：${cfg_dir}"
      fi
    fi
  done

  ps_lifecycle_print_summary "cleanup"
}

ps_lifecycle_reset_state() {
  ps_print_header "重置项目状态"
  ps_log_info "模式：reset"

  if ! ps_require_jq; then
    ps_log_error "reset 需要 jq"
    return 2
  fi

  if ! ps_lifecycle_confirm "即将重置项目状态与配置（保留框架安装）。是否继续？" "N"; then
    ps_log_info "已取消 reset"
    return 0
  fi

  if [[ -f "${PS_MANIFEST}" ]]; then
    ps_backup_file_if_exists "${PS_MANIFEST}" "manifest-before-reset" >/dev/null || true
  fi

  local reset_paths=(
    "${PS_MANIFEST}"
    "${PS_XRAY_CONFIG}"
    "${PS_SINGBOX_CONFIG}"
  )

  local p
  for p in "${reset_paths[@]}"; do
    if [[ -e "${p}" ]]; then
      ps_lifecycle_safe_remove_file "${p}"
    else
      ps_lifecycle_record_skipped "不存在：${p}"
    fi
  done

  ps_init_manifest
  ps_lifecycle_record_removed "manifest 已重建为初始状态"
  ps_lifecycle_print_summary "reset"
}

ps_lifecycle_preserve_data_report() {
  ps_lifecycle_record_preserved "manifest：${PS_MANIFEST}"
  ps_lifecycle_record_preserved "Xray 配置：${PS_XRAY_CONFIG}"
  ps_lifecycle_record_preserved "sing-box 配置：${PS_SINGBOX_CONFIG}"
  ps_lifecycle_record_preserved "证书目录：${PS_CERT_DIR}"
  ps_lifecycle_record_preserved "日志目录：${PS_LOG_DIR}"
  ps_lifecycle_record_preserved "导出目录：${PS_OUTPUT_DIR}"
}

ps_lifecycle_print_summary() {
  local mode="${1:-unknown}"
  local item

  ps_print_header "生命周期操作结果"
  printf "模式：%s\n" "${mode}"
  printf "统计：删除=%s，保留=%s，跳过=%s\n" "${#PS_LIFECYCLE_REMOVED[@]}" "${#PS_LIFECYCLE_PRESERVED[@]}" "${#PS_LIFECYCLE_SKIPPED[@]}"

  printf "\n删除项：\n"
  if [[ "${#PS_LIFECYCLE_REMOVED[@]}" -eq 0 ]]; then
    printf -- "- 无\n"
  else
    for item in "${PS_LIFECYCLE_REMOVED[@]}"; do
      printf -- "- %s\n" "${item}"
    done
  fi

  printf "\n保留项：\n"
  if [[ "${#PS_LIFECYCLE_PRESERVED[@]}" -eq 0 ]]; then
    printf -- "- 无\n"
  else
    for item in "${PS_LIFECYCLE_PRESERVED[@]}"; do
      printf -- "- %s\n" "${item}"
    done
  fi

  printf "\n跳过项：\n"
  if [[ "${#PS_LIFECYCLE_SKIPPED[@]}" -eq 0 ]]; then
    printf -- "- 无\n"
  else
    for item in "${PS_LIFECYCLE_SKIPPED[@]}"; do
      printf -- "- %s\n" "${item}"
    done
  fi
}

ps_lifecycle_confirm_uninstall() {
  local mode="${1:-keep-data}"

  ps_print_header "卸载确认"
  if [[ "${mode}" == "purge" ]]; then
    printf "即将执行完全清理（Purge）。\n"
    printf "将删除启动器、服务、项目目录、运行目录、配置、证书、日志、状态与导出。\n"
    printf "此操作不可恢复。\n"
    if ! ps_lifecycle_confirm "是否继续？" "N"; then
      return 1
    fi

    if [[ "${PS_LIFECYCLE_ASSUME_YES}" == "1" ]]; then
      ps_log_warn "已启用 --yes，跳过 PURGE 二次口令确认。"
      return 0
    fi

    local token=""
    read -r -p "请输入 PURGE 以确认完全清理：" token
    if [[ "${token}" != "PURGE" ]]; then
      ps_log_warn "未输入 PURGE，已取消完全清理。"
      return 1
    fi
    return 0
  fi

  printf "即将卸载 kprxy（保留数据模式）。\n"
  printf "将删除启动器与 kprxy 自有服务，不删除配置、证书、日志、导出和状态文件。\n"
  ps_lifecycle_confirm "是否继续？" "N"
}

ps_lifecycle_uninstall_keep_data() {
  ps_print_header "卸载 kprxy（保留数据）"
  ps_log_info "模式：uninstall keep-data"

  if ! ps_lifecycle_confirm_uninstall keep-data; then
    ps_log_info "已取消卸载"
    return 0
  fi

  ps_lifecycle_remove_services
  ps_lifecycle_remove_launcher
  ps_lifecycle_remove_cron_entries
  ps_lifecycle_safe_remove_file "${PS_XRAY_BIN}"
  ps_lifecycle_safe_remove_file "${PS_SINGBOX_BIN}"

  ps_lifecycle_preserve_data_report
  ps_lifecycle_print_summary "uninstall --keep-data"
}

ps_lifecycle_uninstall_purge() {
  ps_print_header "卸载 kprxy（完全清理）"
  ps_log_info "模式：uninstall purge"

  if ! ps_lifecycle_confirm_uninstall purge; then
    ps_log_info "已取消完全清理"
    return 0
  fi

  ps_lifecycle_remove_services
  ps_lifecycle_remove_launcher
  ps_lifecycle_remove_cron_entries

  local purge_paths=(
    "${PS_MANIFEST}"
    "${PS_STATE_DIR}"
    "${PS_OUTPUT_DIR}"
    "${PS_BACKUP_DIR}"
    "${PS_HOME_DIR}"
    "${PS_ROOT_DIR}/.runtime"
    "${PS_ROOT_DIR}/output"
    "${PS_ROOT_DIR}/backups"
    "${PS_ROOT_DIR}/state/repo-meta.conf"
    "${PS_ROOT_DIR}/state/.launcher-path-hint-shown"
  )

  local p
  for p in "${purge_paths[@]}"; do
    if [[ -d "${p}" ]]; then
      ps_lifecycle_safe_remove_dir "${p}"
    elif [[ -f "${p}" ]]; then
      ps_lifecycle_safe_remove_file "${p}"
    else
      ps_lifecycle_record_skipped "路径不存在：${p}"
    fi
  done

  ps_lifecycle_print_summary "uninstall --purge"
}

ps_lifecycle_uninstall() {
  local mode="${1:-keep-data}"
  PS_LIFECYCLE_REMOVED=()
  PS_LIFECYCLE_PRESERVED=()
  PS_LIFECYCLE_SKIPPED=()

  case "${mode}" in
    keep-data|normal)
      ps_lifecycle_uninstall_keep_data
      ;;
    purge)
      ps_lifecycle_uninstall_purge
      ;;
    *)
      ps_log_error "不支持的卸载模式：${mode}"
      return 2
      ;;
  esac
}

ps_lifecycle_cleanup() {
  PS_LIFECYCLE_REMOVED=()
  PS_LIFECYCLE_PRESERVED=()
  PS_LIFECYCLE_SKIPPED=()

  if ! ps_lifecycle_confirm "即将清理临时/缓存/导出产物，是否继续？" "N"; then
    ps_log_info "已取消 cleanup"
    return 0
  fi

  ps_lifecycle_cleanup_transient
}

ps_lifecycle_reset() {
  PS_LIFECYCLE_REMOVED=()
  PS_LIFECYCLE_PRESERVED=()
  PS_LIFECYCLE_SKIPPED=()
  ps_lifecycle_reset_state
}
