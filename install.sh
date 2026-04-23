#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PS_BOOTSTRAP_INSTALL_DIR="${PS_BOOTSTRAP_INSTALL_DIR:-${HOME}/proxy-stack}"
PS_BOOTSTRAP_GH_USER="${PS_BOOTSTRAP_GH_USER:-<user>}"
PS_BOOTSTRAP_GH_REPO="${PS_BOOTSTRAP_GH_REPO:-<repo>}"
PS_BOOTSTRAP_GH_BRANCH="${PS_BOOTSTRAP_GH_BRANCH:-<branch>}"
PS_MODE="${PS_MODE:-main}"
PS_BOOTSTRAP_ONLY=0
PS_REMOTE_UPGRADE=0
PS_SHOW_HELP=0
PS_RUNTIME_ARGS=()

ps_cli_print_help() {
  cat <<'EOF'
Proxy Stack installer/launcher

Options:
  --mode <main|forward>      Run main framework menu or forwarding-only menu
  --install-dir <path>       Target directory for remote bootstrap install
  --gh-user <user>           GitHub owner for remote bootstrap
  --gh-repo <repo>           GitHub repository for remote bootstrap
  --gh-branch <branch>       GitHub branch/tag for remote bootstrap
  --bootstrap-only           Download/sync project files only, do not launch menu
  --upgrade                  Upgrade existing bootstrap install in --install-dir
  -h, --help                 Show this help message

Remote install example:
  bash <(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/<branch>/install.sh)

Forward-only remote launch:
  bash <(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/<branch>/install.sh) --mode forward
EOF
}

ps_cli_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir)
        shift
        [[ $# -gt 0 ]] || { printf "Missing value for --install-dir\n" >&2; exit 2; }
        PS_BOOTSTRAP_INSTALL_DIR="$1"
        ;;
      --gh-user)
        shift
        [[ $# -gt 0 ]] || { printf "Missing value for --gh-user\n" >&2; exit 2; }
        PS_BOOTSTRAP_GH_USER="$1"
        ;;
      --gh-repo)
        shift
        [[ $# -gt 0 ]] || { printf "Missing value for --gh-repo\n" >&2; exit 2; }
        PS_BOOTSTRAP_GH_REPO="$1"
        ;;
      --gh-branch)
        shift
        [[ $# -gt 0 ]] || { printf "Missing value for --gh-branch\n" >&2; exit 2; }
        PS_BOOTSTRAP_GH_BRANCH="$1"
        ;;
      --mode)
        shift
        [[ $# -gt 0 ]] || { printf "Missing value for --mode\n" >&2; exit 2; }
        PS_MODE="$1"
        ;;
      --bootstrap-only)
        PS_BOOTSTRAP_ONLY=1
        ;;
      --upgrade)
        PS_REMOTE_UPGRADE=1
        ;;
      -h|--help)
        PS_SHOW_HELP=1
        ;;
      *)
        PS_RUNTIME_ARGS+=("$1")
        ;;
    esac
    shift || true
  done
}

ps_bootstrap_info() {
  printf "[bootstrap] %s\n" "$*"
}

ps_bootstrap_error() {
  printf "[bootstrap] ERROR: %s\n" "$*" >&2
}

ps_bootstrap_require_cmd() {
  local cmd="${1}"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    ps_bootstrap_error "Required command not found: ${cmd}"
    return 1
  fi
}

ps_bootstrap_validate_repo_meta() {
  if [[ "${PS_BOOTSTRAP_GH_USER}" == "<user>" || "${PS_BOOTSTRAP_GH_REPO}" == "<repo>" || "${PS_BOOTSTRAP_GH_BRANCH}" == "<branch>" ]]; then
    ps_bootstrap_error "GitHub metadata is still placeholder values."
    ps_bootstrap_error "Set --gh-user, --gh-repo, and --gh-branch (or env vars PS_BOOTSTRAP_GH_*)."
    return 1
  fi
}

ps_bootstrap_sync_repo() {
  local source_dir="${1}"

  local required_paths=(
    "install.sh"
    "forward.sh"
    "lib/common.sh"
    "templates/xray/base.json.tpl"
    "templates/singbox/base.json.tpl"
    "state/manifest.json"
    "README.md"
  )

  local required
  for required in "${required_paths[@]}"; do
    if [[ ! -e "${source_dir}/${required}" ]]; then
      ps_bootstrap_error "Downloaded project is incomplete, missing: ${required}"
      return 1
    fi
  done

  mkdir -p "${PS_BOOTSTRAP_INSTALL_DIR}"

  if [[ -f "${PS_BOOTSTRAP_INSTALL_DIR}/lib/common.sh" && "${PS_REMOTE_UPGRADE}" -eq 0 ]]; then
    ps_bootstrap_error "Install path already contains a proxy-stack project: ${PS_BOOTSTRAP_INSTALL_DIR}"
    ps_bootstrap_error "Use --upgrade to update the existing installation."
    return 1
  fi

  rm -rf "${PS_BOOTSTRAP_INSTALL_DIR}/lib" "${PS_BOOTSTRAP_INSTALL_DIR}/templates"
  cp -a "${source_dir}/lib" "${PS_BOOTSTRAP_INSTALL_DIR}/lib"
  cp -a "${source_dir}/templates" "${PS_BOOTSTRAP_INSTALL_DIR}/templates"
  cp -a "${source_dir}/install.sh" "${PS_BOOTSTRAP_INSTALL_DIR}/install.sh"
  cp -a "${source_dir}/forward.sh" "${PS_BOOTSTRAP_INSTALL_DIR}/forward.sh"
  cp -a "${source_dir}/README.md" "${PS_BOOTSTRAP_INSTALL_DIR}/README.md"

  mkdir -p "${PS_BOOTSTRAP_INSTALL_DIR}/state" "${PS_BOOTSTRAP_INSTALL_DIR}/output" "${PS_BOOTSTRAP_INSTALL_DIR}/backups"
  if [[ ! -f "${PS_BOOTSTRAP_INSTALL_DIR}/state/manifest.json" ]]; then
    cp -a "${source_dir}/state/manifest.json" "${PS_BOOTSTRAP_INSTALL_DIR}/state/manifest.json"
  fi

  chmod +x "${PS_BOOTSTRAP_INSTALL_DIR}/install.sh" "${PS_BOOTSTRAP_INSTALL_DIR}/forward.sh"
}

ps_bootstrap_from_github() {
  ps_bootstrap_require_cmd curl || return 2
  ps_bootstrap_require_cmd tar || return 2
  ps_bootstrap_require_cmd mktemp || return 2
  ps_bootstrap_require_cmd find || return 2

  ps_bootstrap_validate_repo_meta || return 2

  local archive_url="https://codeload.github.com/${PS_BOOTSTRAP_GH_USER}/${PS_BOOTSTRAP_GH_REPO}/tar.gz/${PS_BOOTSTRAP_GH_BRANCH}"
  local tmpdir
  tmpdir="$(mktemp -d)"
  local archive_file="${tmpdir}/repo.tar.gz"
  local extract_dir="${tmpdir}/extract"

  ps_bootstrap_info "Downloading project archive: ${archive_url}"
  if ! curl -fsSL "${archive_url}" -o "${archive_file}"; then
    rm -rf "${tmpdir}"
    ps_bootstrap_error "Download failed: ${archive_url}"
    return 2
  fi

  if [[ ! -s "${archive_file}" ]]; then
    rm -rf "${tmpdir}"
    ps_bootstrap_error "Downloaded archive is empty."
    return 2
  fi

  mkdir -p "${extract_dir}"
  if ! tar -xzf "${archive_file}" -C "${extract_dir}"; then
    rm -rf "${tmpdir}"
    ps_bootstrap_error "Failed to extract downloaded archive."
    return 2
  fi

  local source_dir
  source_dir="$(find "${extract_dir}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ -z "${source_dir}" ]]; then
    rm -rf "${tmpdir}"
    ps_bootstrap_error "Could not locate extracted project directory."
    return 2
  fi

  ps_bootstrap_sync_repo "${source_dir}" || {
    rm -rf "${tmpdir}"
    return 2
  }

  rm -rf "${tmpdir}"
  ps_bootstrap_info "Project files synced to ${PS_BOOTSTRAP_INSTALL_DIR}"

  if [[ "${PS_BOOTSTRAP_ONLY}" -eq 1 ]]; then
    ps_bootstrap_info "Bootstrap-only mode completed."
    return 0
  fi

  local entry_script="install.sh"
  if [[ "${PS_MODE}" == "forward" ]]; then
    entry_script="forward.sh"
  fi

  if [[ ! -x "${PS_BOOTSTRAP_INSTALL_DIR}/${entry_script}" ]]; then
    ps_bootstrap_error "Entry script missing after bootstrap: ${entry_script}"
    return 2
  fi

  ps_bootstrap_info "Launching ${entry_script}"
  exec bash "${PS_BOOTSTRAP_INSTALL_DIR}/${entry_script}" "${PS_RUNTIME_ARGS[@]}"
}

ps_cli_parse_args "$@"

if [[ "${PS_SHOW_HELP}" -eq 1 ]]; then
  ps_cli_print_help
  exit 0
fi

if [[ ! -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
  ps_bootstrap_from_github
  exit $?
fi

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/logger.sh
source "${SCRIPT_DIR}/lib/logger.sh"
# shellcheck source=lib/ui.sh
source "${SCRIPT_DIR}/lib/ui.sh"
# shellcheck source=lib/crypto.sh
source "${SCRIPT_DIR}/lib/crypto.sh"
# shellcheck source=lib/stack.sh
source "${SCRIPT_DIR}/lib/stack.sh"
# shellcheck source=lib/inbound.sh
source "${SCRIPT_DIR}/lib/inbound.sh"
# shellcheck source=lib/outbound.sh
source "${SCRIPT_DIR}/lib/outbound.sh"
# shellcheck source=lib/route.sh
source "${SCRIPT_DIR}/lib/route.sh"
# shellcheck source=lib/forward.sh
source "${SCRIPT_DIR}/lib/forward.sh"
# shellcheck source=lib/cert.sh
source "${SCRIPT_DIR}/lib/cert.sh"
# shellcheck source=lib/render.sh
source "${SCRIPT_DIR}/lib/render.sh"
# shellcheck source=lib/subscribe.sh
source "${SCRIPT_DIR}/lib/subscribe.sh"
# shellcheck source=lib/xray.sh
source "${SCRIPT_DIR}/lib/xray.sh"
# shellcheck source=lib/singbox.sh
source "${SCRIPT_DIR}/lib/singbox.sh"
# shellcheck source=lib/systemd.sh
source "${SCRIPT_DIR}/lib/systemd.sh"
# shellcheck source=lib/diagnostic.sh
source "${SCRIPT_DIR}/lib/diagnostic.sh"
# shellcheck source=lib/backup.sh
source "${SCRIPT_DIR}/lib/backup.sh"

ps_run_action() {
  local action="${1}"
  shift || true

  if ! "${action}" "$@"; then
    ps_ui_error "Action failed: ${action}"
  fi
  ps_pause
}

ps_check_dependencies() {
  ps_ui_header "Dependency Check"
  local required=(jq curl openssl tar sed awk grep)
  local optional=(systemctl ss journalctl base64)
  local cmd
  local missing=0

  for cmd in "${required[@]}"; do
    if ps_command_exists "${cmd}"; then
      printf "[OK] %s\n" "${cmd}"
    else
      if [[ "${cmd}" == "jq" ]]; then
        printf "[MISSING] %s (required for manifest/state runtime)\n" "${cmd}"
      else
        printf "[MISSING] %s\n" "${cmd}"
      fi
      missing=1
    fi
  done

  for cmd in "${optional[@]}"; do
    if ps_command_exists "${cmd}"; then
      printf "[OK] %s\n" "${cmd}"
    else
      printf "[WARN] optional tool missing: %s\n" "${cmd}"
    fi
  done

  if [[ "${missing}" -ne 0 ]]; then
    ps_ui_error "Preflight dependency check failed."
    return 1
  fi

  ps_ui_success "Required dependencies are available."
  return 0
}

ps_preflight_checks() {
  if ! ps_check_dependencies; then
    if ! ps_command_exists jq; then
      ps_ui_error "Blocked: jq-dependent runtime validation/execution cannot run in this environment."
      printf "Remediation (Debian/Ubuntu): sudo apt-get update && sudo apt-get install -y jq\n"
    fi
    return 2
  fi

  if ! ps_require_jq; then
    return 2
  fi

  return 0
}

ps_menu_uninstall_engines() {
  while true; do
    ps_ui_menu_select "Uninstall Engines" "Back" "Choose" \
      "Uninstall xray-core" \
      "Uninstall sing-box" \
      "Uninstall both"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_xray_uninstall ;;
      2) ps_run_action ps_singbox_uninstall ;;
      3) ps_run_action ps_xray_uninstall; ps_run_action ps_singbox_uninstall ;;
      0) break ;;
      *) ps_ui_warn "Invalid selection"; ps_pause ;;
    esac
  done
}

ps_menu_forwarding() {
  while true; do
    ps_ui_menu_select "Forwarding Management" "Back" "Choose" \
      "List forwarding entries" \
      "Create forwarding entry" \
      "Delete forwarding entry" \
      "Test route matching"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_forward_list ;;
      2) ps_run_action ps_forward_create ;;
      3) ps_run_action ps_forward_delete ;;
      4) ps_run_action ps_route_test_match ;;
      0) break ;;
      *) ps_ui_warn "Invalid selection"; ps_pause ;;
    esac
  done
}

ps_menu_stack_management() {
  while true; do
    ps_ui_menu_select "Stack Management" "Back" "Choose" \
      "List installed stacks" \
      "Create new stack" \
      "Edit stack" \
      "Delete stack" \
      "Enable/disable stack" \
      "Re-render config"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_stack_list ;;
      2) ps_run_action ps_stack_create ;;
      3) ps_run_action ps_stack_edit ;;
      4) ps_run_action ps_stack_delete ;;
      5) ps_run_action ps_stack_toggle ;;
      6) ps_run_action ps_stack_rerender ;;
      0) break ;;
      *) ps_ui_warn "Invalid selection"; ps_pause ;;
    esac
  done
}

ps_menu_inbound_management() {
  while true; do
    ps_ui_menu_select "Inbound Management" "Back" "Choose" \
      "List inbounds" \
      "Create public server inbound" \
      "Create local inbound" \
      "Edit inbound" \
      "Delete inbound" \
      "Bind inbound to stack"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_inbound_list ;;
      2) ps_run_action ps_inbound_create_public ;;
      3) ps_run_action ps_inbound_create_local ;;
      4) ps_run_action ps_inbound_edit ;;
      5) ps_run_action ps_inbound_delete ;;
      6) ps_run_action ps_inbound_bind_stack ;;
      0) break ;;
      *) ps_ui_warn "Invalid selection"; ps_pause ;;
    esac
  done
}

ps_menu_outbound_routing() {
  while true; do
    ps_ui_menu_select "Outbounds and Routing" "Back" "Choose" \
      "List outbounds" \
      "Create outbound" \
      "Edit outbound" \
      "Delete outbound" \
      "List routing rules" \
      "Create routing rule" \
      "Forwarding management (separate module)" \
      "Reorder routing priority" \
      "Test route matching"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_outbound_list ;;
      2) ps_run_action ps_outbound_create ;;
      3) ps_run_action ps_outbound_edit ;;
      4) ps_run_action ps_outbound_delete ;;
      5) ps_run_action ps_route_list ;;
      6) ps_run_action ps_route_create_rule ;;
      7) ps_menu_forwarding ;;
      8) ps_run_action ps_route_reorder_priority ;;
      9) ps_run_action ps_route_test_match ;;
      0) break ;;
      *) ps_ui_warn "Invalid selection"; ps_pause ;;
    esac
  done
}

ps_menu_cert_domain() {
  while true; do
    ps_ui_menu_select "Certificates and Domains" "Back" "Choose" \
      "List certificates" \
      "Issue certificate (ACME)" \
      "Install custom certificate" \
      "Configure auto-renewal" \
      "Test renewal" \
      "Manage SNI / REALITY handshake parameters"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_cert_list ;;
      2) ps_run_action ps_cert_issue_acme ;;
      3) ps_run_action ps_cert_install_custom ;;
      4) ps_run_action ps_cert_configure_auto_renew ;;
      5) ps_run_action ps_cert_test_renewal ;;
      6) ps_run_action ps_cert_manage_reality_params ;;
      0) break ;;
      *) ps_ui_warn "Invalid selection"; ps_pause ;;
    esac
  done
}

ps_menu_subscribe_export() {
  while true; do
    ps_ui_menu_select "Subscriptions and Export" "Back" "Choose" \
      "Generate share links" \
      "Generate Base64 subscription" \
      "Export Clash.Meta" \
      "Export Xray client config" \
      "Export sing-box client config" \
      "Export initialized rules bundle" \
      "Export client config + initialized rules bundle" \
      "Export local proxy templates with routing"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_sub_generate_share_links ;;
      2) ps_run_action ps_sub_generate_base64_subscription ;;
      3) ps_run_action ps_sub_export_clash_meta ;;
      4) ps_run_action ps_sub_export_xray_client_config ;;
      5) ps_run_action ps_sub_export_singbox_client_config ;;
      6) ps_run_action ps_sub_export_initialized_rules_bundle ;;
      7) ps_run_action ps_sub_export_client_with_rules_bundle ;;
      8) ps_run_action ps_sub_export_local_proxy_templates ;;
      0) break ;;
      *) ps_ui_warn "Invalid selection"; ps_pause ;;
    esac
  done
}

ps_menu_logs_diagnostics() {
  while true; do
    ps_ui_menu_select "Logs and Diagnostics" "Back" "Choose" \
      "View installation log" \
      "View Xray service log" \
      "View sing-box service log" \
      "View access log" \
      "View error log" \
      "Change log level" \
      "Toggle DNS logging" \
      "Configure log rotation" \
      "Export diagnostic bundle" \
      "Tail logs in real time"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_diag_view_install_log ;;
      2) ps_run_action ps_diag_view_xray_service_log ;;
      3) ps_run_action ps_diag_view_singbox_service_log ;;
      4) ps_run_action ps_diag_view_access_log ;;
      5) ps_run_action ps_diag_view_error_log ;;
      6) ps_run_action ps_diag_change_log_level ;;
      7) ps_run_action ps_diag_toggle_dns_logging ;;
      8) ps_run_action ps_diag_configure_log_rotation ;;
      9) ps_run_action ps_diag_export_bundle ;;
      10) ps_run_action ps_diag_tail_logs ;;
      0) break ;;
      *) ps_ui_warn "Invalid selection"; ps_pause ;;
    esac
  done
}

ps_menu_engines_services() {
  while true; do
    ps_ui_menu_select "Engines and Services" "Back" "Choose" \
      "Install/upgrade xray-core" \
      "Install/upgrade sing-box" \
      "Start services" \
      "Stop services" \
      "Restart services" \
      "Reload config" \
      "Show versions" \
      "Uninstall engines" \
      "Install/update systemd units"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_xray_install_upgrade ;;
      2) ps_run_action ps_singbox_install_upgrade ;;
      3) ps_run_action ps_systemd_start_services ;;
      4) ps_run_action ps_systemd_stop_services ;;
      5) ps_run_action ps_systemd_restart_services ;;
      6)
        ps_run_action ps_render_all
        ps_run_action ps_systemd_reload_services
        ;;
      7)
        ps_run_action ps_xray_show_version
        ps_run_action ps_singbox_show_version
        ;;
      8) ps_menu_uninstall_engines ;;
      9) ps_run_action ps_systemd_install_units ;;
      0) break ;;
      *) ps_ui_warn "Invalid selection"; ps_pause ;;
    esac
  done
}

ps_menu_backup_restore() {
  while true; do
    ps_ui_menu_select "Backup and Restore" "Back" "Choose" \
      "Backup manifest" \
      "Backup config files" \
      "Backup certificates" \
      "Restore backup" \
      "Roll back to previous version"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_backup_manifest ;;
      2) ps_run_action ps_backup_configs ;;
      3) ps_run_action ps_backup_certificates ;;
      4) ps_run_action ps_backup_restore ;;
      5) ps_run_action ps_backup_rollback_previous ;;
      0) break ;;
      *) ps_ui_warn "Invalid selection"; ps_pause ;;
    esac
  done
}

main() {
  ps_prepare_runtime_dirs
  ps_logger_init

  if [[ "${PS_BOOTSTRAP_ONLY}" -eq 1 ]]; then
    ps_ui_info "Local repository mode detected, bootstrap-only flag has no effect."
    exit 0
  fi

  if [[ "${PS_REMOTE_UPGRADE}" -eq 1 ]]; then
    ps_ui_info "Upgrade flag is intended for remote bootstrap usage. Continuing with local menu mode."
  fi

  if [[ "${#PS_RUNTIME_ARGS[@]}" -gt 0 ]]; then
    ps_ui_warn "Ignoring unsupported positional arguments: ${PS_RUNTIME_ARGS[*]}"
  fi

  ps_preflight_checks || exit $?
  ps_init_manifest

  if [[ "${PS_MODE}" == "forward" ]]; then
    ps_menu_forwarding
    ps_ui_info "Bye"
    exit 0
  fi

  while true; do
    ps_ui_menu_select "Proxy Stack Main Menu" "Exit" "Choose" \
      "Stack Management" \
      "Inbound Management" \
      "Outbounds and Routing" \
      "Certificates and Domains" \
      "Subscriptions and Export" \
      "Logs and Diagnostics" \
      "Engines and Services" \
      "Backup and Restore"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_menu_stack_management ;;
      2) ps_menu_inbound_management ;;
      3) ps_menu_outbound_routing ;;
      4) ps_menu_cert_domain ;;
      5) ps_menu_subscribe_export ;;
      6) ps_menu_logs_diagnostics ;;
      7) ps_menu_engines_services ;;
      8) ps_menu_backup_restore ;;
      0)
        ps_ui_info "Bye"
        break
        ;;
      *)
        ps_ui_warn "Invalid selection"
        ps_pause
        ;;
    esac
  done
}

main "$@"
