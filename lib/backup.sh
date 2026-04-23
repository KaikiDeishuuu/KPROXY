#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_BACKUP_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_BACKUP_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"

ps_backup_manifest() {
  ps_print_header "备份 Manifest"
  local target_dir file_path
  target_dir="${PS_BACKUP_DIR}/manifest"
  mkdir -p "${target_dir}"
  file_path="${target_dir}/manifest-$(ps_now_compact).json"
  cp -a "${PS_MANIFEST}" "${file_path}"
  ps_log_success "Manifest 备份已创建： ${file_path}"
}

ps_backup_configs() {
  ps_print_header "备份配置文件"
  local target_dir file_path
  target_dir="${PS_BACKUP_DIR}/configs"
  mkdir -p "${target_dir}"
  file_path="${target_dir}/configs-$(ps_now_compact).tar.gz"

  tar -czf "${file_path}" -C / "${PS_ETC_DIR#/}" 2>/dev/null || tar -czf "${file_path}" -C "${PS_ROOT_DIR}" "$(realpath --relative-to="${PS_ROOT_DIR}" "${PS_ETC_DIR}")"
  ps_log_success "配置备份已创建： ${file_path}"
}

ps_backup_certificates() {
  ps_print_header "备份证书"
  local target_dir file_path
  target_dir="${PS_BACKUP_DIR}/certificates"
  mkdir -p "${target_dir}"
  file_path="${target_dir}/certificates-$(ps_now_compact).tar.gz"

  if [[ ! -d "${PS_CERT_DIR}" ]]; then
    ps_log_warn "证书目录不存在：${PS_CERT_DIR}"
    return 1
  fi

  tar -czf "${file_path}" -C "${PS_CERT_DIR}" .
  ps_log_success "证书备份已创建： ${file_path}"
}

ps_backup_restore() {
  ps_print_header "恢复备份"
  local file_path
  file_path="$(ps_prompt_required "备份文件路径")"

  if [[ ! -f "${file_path}" ]]; then
    ps_log_error "文件不存在：${file_path}"
    return 1
  fi

  if ! ps_confirm "从 ${file_path} 恢复吗？这可能覆盖当前文件。" "N"; then
    ps_log_info "已取消"
    return 0
  fi

  case "${file_path}" in
    *.json)
      cp -a "${file_path}" "${PS_MANIFEST}"
      ps_log_success "Manifest 已恢复"
      ;;
    *.tar.gz)
      if ps_is_root; then
        tar -xzf "${file_path}" -C /
      else
        local restore_dir="${PS_ROOT_DIR}/.runtime/restore"
        mkdir -p "${restore_dir}"
        tar -xzf "${file_path}" -C "${restore_dir}"
        ps_log_warn "非 root 模式已将归档恢复到 ${restore_dir}"
      fi
      ps_log_success "归档已恢复"
      ;;
    *)
      ps_log_error "不支持的备份文件格式"
      return 1
      ;;
  esac
}

ps_backup_rollback_previous() {
  ps_print_header "回滚到上一个 Manifest"
  local latest_backup
  latest_backup="$(ls -1t "${PS_BACKUP_DIR}/manifest"/manifest-*.json 2>/dev/null | head -n 1 || true)"

  if [[ -z "${latest_backup}" ]]; then
    ps_log_warn "没有可用的 Manifest 备份"
    return 1
  fi

  if ! ps_confirm "将 Manifest 回滚到 ${latest_backup}?" "N"; then
    ps_log_info "已取消"
    return 0
  fi

  cp -a "${latest_backup}" "${PS_MANIFEST}"
  ps_log_success "回滚完成"
}
