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
  ps_print_header "Backup Manifest"
  local target_dir file_path
  target_dir="${PS_BACKUP_DIR}/manifest"
  mkdir -p "${target_dir}"
  file_path="${target_dir}/manifest-$(ps_now_compact).json"
  cp -a "${PS_MANIFEST}" "${file_path}"
  ps_log_success "Manifest backup created: ${file_path}"
}

ps_backup_configs() {
  ps_print_header "Backup Config Files"
  local target_dir file_path
  target_dir="${PS_BACKUP_DIR}/configs"
  mkdir -p "${target_dir}"
  file_path="${target_dir}/configs-$(ps_now_compact).tar.gz"

  tar -czf "${file_path}" -C / "${PS_ETC_DIR#/}" 2>/dev/null || tar -czf "${file_path}" -C "${PS_ROOT_DIR}" "$(realpath --relative-to="${PS_ROOT_DIR}" "${PS_ETC_DIR}")"
  ps_log_success "Config backup created: ${file_path}"
}

ps_backup_certificates() {
  ps_print_header "Backup Certificates"
  local target_dir file_path
  target_dir="${PS_BACKUP_DIR}/certificates"
  mkdir -p "${target_dir}"
  file_path="${target_dir}/certificates-$(ps_now_compact).tar.gz"

  if [[ ! -d "${PS_CERT_DIR}" ]]; then
    ps_log_warn "Certificate directory not found: ${PS_CERT_DIR}"
    return 1
  fi

  tar -czf "${file_path}" -C "${PS_CERT_DIR}" .
  ps_log_success "Certificate backup created: ${file_path}"
}

ps_backup_restore() {
  ps_print_header "Restore Backup"
  local file_path
  file_path="$(ps_prompt_required "Backup file path")"

  if [[ ! -f "${file_path}" ]]; then
    ps_log_error "File not found: ${file_path}"
    return 1
  fi

  if ! ps_confirm "Restore from ${file_path}? This may overwrite current files." "N"; then
    ps_log_info "Cancelled"
    return 0
  fi

  case "${file_path}" in
    *.json)
      cp -a "${file_path}" "${PS_MANIFEST}"
      ps_log_success "Manifest restored"
      ;;
    *.tar.gz)
      if ps_is_root; then
        tar -xzf "${file_path}" -C /
      else
        local restore_dir="${PS_ROOT_DIR}/.runtime/restore"
        mkdir -p "${restore_dir}"
        tar -xzf "${file_path}" -C "${restore_dir}"
        ps_log_warn "Non-root mode restored archive under ${restore_dir}"
      fi
      ps_log_success "Archive restored"
      ;;
    *)
      ps_log_error "Unsupported backup file format"
      return 1
      ;;
  esac
}

ps_backup_rollback_previous() {
  ps_print_header "Rollback to Previous Manifest"
  local latest_backup
  latest_backup="$(ls -1t "${PS_BACKUP_DIR}/manifest"/manifest-*.json 2>/dev/null | head -n 1 || true)"

  if [[ -z "${latest_backup}" ]]; then
    ps_log_warn "No manifest backup available"
    return 1
  fi

  if ! ps_confirm "Rollback manifest to ${latest_backup}?" "N"; then
    ps_log_info "Cancelled"
    return 0
  fi

  cp -a "${latest_backup}" "${PS_MANIFEST}"
  ps_log_success "Rollback complete"
}
