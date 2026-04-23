#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PS_BOOTSTRAP_INSTALL_DIR="${PS_BOOTSTRAP_INSTALL_DIR:-}"
PS_BOOTSTRAP_INSTALL_DIR_EXPLICIT=0
DEFAULT_GH_USER="KaikiDeishuuu"
DEFAULT_GH_REPO="KPROXY"
DEFAULT_GH_BRANCH="main"
PS_DEFAULT_GH_USER="${PS_BOOTSTRAP_GH_USER:-${DEFAULT_GH_USER}}"
PS_DEFAULT_GH_REPO="${PS_BOOTSTRAP_GH_REPO:-${DEFAULT_GH_REPO}}"
PS_DEFAULT_GH_BRANCH="${PS_BOOTSTRAP_GH_BRANCH:-${DEFAULT_GH_BRANCH}}"
PS_BOOTSTRAP_GH_USER="${PS_DEFAULT_GH_USER}"
PS_BOOTSTRAP_GH_REPO="${PS_DEFAULT_GH_REPO}"
PS_BOOTSTRAP_GH_BRANCH="${PS_DEFAULT_GH_BRANCH}"
PS_BOOTSTRAP_GH_USER_EXPLICIT=0
PS_BOOTSTRAP_GH_REPO_EXPLICIT=0
PS_BOOTSTRAP_GH_BRANCH_EXPLICIT=0
PS_BOOTSTRAP_LAUNCHER_PATH="${PS_BOOTSTRAP_LAUNCHER_PATH:-}"
PS_LOCAL_REPO_MODE=0
PS_MODE="${PS_MODE:-main}"
PS_BOOTSTRAP_ONLY=0
PS_REMOTE_UPGRADE=0
PS_SHOW_HELP=0
PS_RUNTIME_ARGS=()

ps_cli_print_help() {
  cat <<'EOF'
Proxy 协议栈 安装器/启动器

参数：
  --mode <main|forward>      运行主菜单或仅转发菜单
  --install-dir <path>       远程引导安装目标目录
  --gh-user <user>           远程引导 GitHub 用户名
  --gh-repo <repo>           远程引导 GitHub 仓库名
  --gh-branch <branch>       远程引导 GitHub 分支/标签
  --bootstrap-only           仅下载/同步项目文件，不启动菜单
  --upgrade                  升级 --install-dir 中已有安装
  -h, --help                 显示帮助信息

子命令：
  update                     同步最新脚本/模板到当前安装目录
  export                     一键导出：客户端配置 + 初始化规则包
  doctor                     执行依赖预检
  logs                       查看安装日志
  info                       显示启动器/安装元数据
  config repo                保存仓库元数据供后续更新使用

远程安装示例：
  bash <(curl -fsSL https://raw.githubusercontent.com/KaikiDeishuuu/KPROXY/main/install.sh)

仅转发模式远程启动：
  bash <(curl -fsSL https://raw.githubusercontent.com/KaikiDeishuuu/KPROXY/main/install.sh) --mode forward
EOF
}

ps_cli_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir)
        shift
        [[ $# -gt 0 ]] || { printf "--install-dir 缺少参数值\n" >&2; exit 2; }
        PS_BOOTSTRAP_INSTALL_DIR="$1"
        PS_BOOTSTRAP_INSTALL_DIR_EXPLICIT=1
        ;;
      --gh-user)
        shift
        [[ $# -gt 0 ]] || { printf "--gh-user 缺少参数值\n" >&2; exit 2; }
        PS_BOOTSTRAP_GH_USER="$1"
        PS_BOOTSTRAP_GH_USER_EXPLICIT=1
        ;;
      --gh-repo)
        shift
        [[ $# -gt 0 ]] || { printf "--gh-repo 缺少参数值\n" >&2; exit 2; }
        PS_BOOTSTRAP_GH_REPO="$1"
        PS_BOOTSTRAP_GH_REPO_EXPLICIT=1
        ;;
      --gh-branch)
        shift
        [[ $# -gt 0 ]] || { printf "--gh-branch 缺少参数值\n" >&2; exit 2; }
        PS_BOOTSTRAP_GH_BRANCH="$1"
        PS_BOOTSTRAP_GH_BRANCH_EXPLICIT=1
        ;;
      --mode)
        shift
        [[ $# -gt 0 ]] || { printf "--mode 缺少参数值\n" >&2; exit 2; }
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
  printf "[引导] %s\n" "$*"
}

ps_bootstrap_error() {
  printf "[引导] 错误： %s\n" "$*" >&2
}

ps_bootstrap_require_cmd() {
  local cmd="${1}"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    ps_bootstrap_error "未找到必需命令： ${cmd}"
    return 1
  fi
}

ps_bootstrap_validate_repo_meta() {
  if [[ "${PS_BOOTSTRAP_GH_USER}" == "<user>" || "${PS_BOOTSTRAP_GH_REPO}" == "<repo>" || "${PS_BOOTSTRAP_GH_BRANCH}" == "<branch>" ]]; then
    ps_bootstrap_error "GitHub 元数据仍为占位符。"
    ps_bootstrap_error "请设置 --gh-user、--gh-repo、--gh-branch（或环境变量 PS_BOOTSTRAP_GH_*）。"
    return 1
  fi
}

ps_bootstrap_meta_file() {
  printf "%s/state/repo-meta.conf" "${PS_BOOTSTRAP_INSTALL_DIR}"
}

ps_bootstrap_path_hint_marker() {
  printf "%s/state/.launcher-path-hint-shown" "${PS_BOOTSTRAP_INSTALL_DIR}"
}

ps_bootstrap_value_is_placeholder() {
  local value="${1:-}"
  [[ -z "${value}" || "${value}" =~ ^\<.*\>$ ]]
}

ps_bootstrap_has_real_repo_meta() {
  local user="${1:-}"
  local repo="${2:-}"
  local branch="${3:-}"
  ! ps_bootstrap_value_is_placeholder "${user}" \
    && ! ps_bootstrap_value_is_placeholder "${repo}" \
    && ! ps_bootstrap_value_is_placeholder "${branch}"
}

ps_bootstrap_load_repo_meta() {
  local meta_file
  meta_file="$(ps_bootstrap_meta_file)"
  [[ -f "${meta_file}" ]] || return 1

  local gh_user=""
  local gh_repo=""
  local gh_branch=""
  while IFS='=' read -r key value; do
    case "${key}" in
      gh_user) gh_user="${value}" ;;
      gh_repo) gh_repo="${value}" ;;
      gh_branch) gh_branch="${value}" ;;
    esac
  done < "${meta_file}"

  if ps_bootstrap_has_real_repo_meta "${gh_user}" "${gh_repo}" "${gh_branch}"; then
    printf "%s|%s|%s" "${gh_user}" "${gh_repo}" "${gh_branch}"
    return 0
  fi

  return 1
}

ps_bootstrap_persist_repo_meta() {
  local source_url="${1:-}"
  if ! ps_bootstrap_has_real_repo_meta "${PS_BOOTSTRAP_GH_USER}" "${PS_BOOTSTRAP_GH_REPO}" "${PS_BOOTSTRAP_GH_BRANCH}"; then
    ps_bootstrap_info "仓库元数据不完整，跳过保存。"
    return 0
  fi

  mkdir -p "${PS_BOOTSTRAP_INSTALL_DIR}/state"
  local meta_file
  meta_file="$(ps_bootstrap_meta_file)"
  local tmp
  tmp="$(mktemp "${meta_file}.tmp.XXXXXX")"
  cat > "${tmp}" <<EOF_META
gh_user=${PS_BOOTSTRAP_GH_USER}
gh_repo=${PS_BOOTSTRAP_GH_REPO}
gh_branch=${PS_BOOTSTRAP_GH_BRANCH}
source_url=${source_url}
updated_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF_META
  mv -f "${tmp}" "${meta_file}"
}

ps_bootstrap_resolve_repo_meta_for_update() {
  local resolved_user=""
  local resolved_repo=""
  local resolved_branch=""

  if [[ "${PS_BOOTSTRAP_GH_USER_EXPLICIT}" -eq 1 ]]; then
    resolved_user="${PS_BOOTSTRAP_GH_USER}"
  fi
  if [[ "${PS_BOOTSTRAP_GH_REPO_EXPLICIT}" -eq 1 ]]; then
    resolved_repo="${PS_BOOTSTRAP_GH_REPO}"
  fi
  if [[ "${PS_BOOTSTRAP_GH_BRANCH_EXPLICIT}" -eq 1 ]]; then
    resolved_branch="${PS_BOOTSTRAP_GH_BRANCH}"
  fi

  local persisted=""
  if persisted="$(ps_bootstrap_load_repo_meta 2>/dev/null)"; then
    IFS='|' read -r persisted_user persisted_repo persisted_branch <<< "${persisted}"
    [[ -n "${resolved_user}" ]] || resolved_user="${persisted_user}"
    [[ -n "${resolved_repo}" ]] || resolved_repo="${persisted_repo}"
    [[ -n "${resolved_branch}" ]] || resolved_branch="${persisted_branch}"
  fi

  [[ -n "${resolved_user}" ]] || resolved_user="${PS_DEFAULT_GH_USER}"
  [[ -n "${resolved_repo}" ]] || resolved_repo="${PS_DEFAULT_GH_REPO}"
  [[ -n "${resolved_branch}" ]] || resolved_branch="${PS_DEFAULT_GH_BRANCH}"

  if ! ps_bootstrap_has_real_repo_meta "${resolved_user}" "${resolved_repo}" "${resolved_branch}"; then
    ps_bootstrap_error "无法执行 update：仓库元数据不完整。"
    ps_bootstrap_error "需要：--gh-user、--gh-repo、--gh-branch（或 state/repo-meta.conf 中的已保存元数据）。"
    ps_bootstrap_error "可用以下命令修复元数据："
    ps_bootstrap_error "  kprxy config repo --gh-user <user> --gh-repo <repo> --gh-branch <branch>"
    return 1
  fi

  PS_BOOTSTRAP_GH_USER="${resolved_user}"
  PS_BOOTSTRAP_GH_REPO="${resolved_repo}"
  PS_BOOTSTRAP_GH_BRANCH="${resolved_branch}"
}

ps_bootstrap_resolve_paths() {
  local launcher_lib="${SCRIPT_DIR}/lib/launcher.sh"
  if [[ -f "${launcher_lib}" ]]; then
    # shellcheck source=lib/launcher.sh
    source "${launcher_lib}"
  fi

  if [[ "${PS_BOOTSTRAP_INSTALL_DIR_EXPLICIT}" -eq 1 ]]; then
    : "${PS_BOOTSTRAP_INSTALL_DIR:?}"
  elif [[ "${PS_LOCAL_REPO_MODE}" -eq 1 ]]; then
    PS_BOOTSTRAP_INSTALL_DIR="${SCRIPT_DIR}"
  elif declare -F ps_launcher_resolve_install_dir >/dev/null 2>&1; then
    PS_BOOTSTRAP_INSTALL_DIR="$(ps_launcher_resolve_install_dir "")"
  elif [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    PS_BOOTSTRAP_INSTALL_DIR="/opt/kprxy"
  else
    PS_BOOTSTRAP_INSTALL_DIR="${HOME}/.local/share/kprxy"
  fi

  if [[ -n "${PS_BOOTSTRAP_LAUNCHER_PATH}" ]]; then
    return 0
  fi

  if declare -F ps_launcher_resolve_launcher_path >/dev/null 2>&1; then
    PS_BOOTSTRAP_LAUNCHER_PATH="$(ps_launcher_resolve_launcher_path "")"
  elif [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    PS_BOOTSTRAP_LAUNCHER_PATH="/usr/local/bin/kprxy"
  else
    PS_BOOTSTRAP_LAUNCHER_PATH="${HOME}/.local/bin/kprxy"
  fi
}

ps_bootstrap_install_launcher() {
  local launcher_lib="${PS_BOOTSTRAP_INSTALL_DIR}/lib/launcher.sh"
  if [[ ! -f "${launcher_lib}" ]]; then
    ps_bootstrap_error "缺少启动器辅助文件： ${launcher_lib}"
    return 1
  fi

  # shellcheck source=lib/launcher.sh
  source "${launcher_lib}"
  ps_launcher_install "${PS_BOOTSTRAP_INSTALL_DIR}" "${PS_BOOTSTRAP_LAUNCHER_PATH}" "install.sh"
  ps_launcher_verify "${PS_BOOTSTRAP_LAUNCHER_PATH}" || {
    ps_bootstrap_error "启动器校验失败： ${PS_BOOTSTRAP_LAUNCHER_PATH}"
    return 1
  }

  ps_launcher_maybe_print_path_hint "${PS_BOOTSTRAP_LAUNCHER_PATH}" "$(ps_bootstrap_path_hint_marker)" "install"
  ps_launcher_print_success "${PS_BOOTSTRAP_INSTALL_DIR}" "${PS_BOOTSTRAP_LAUNCHER_PATH}"
}

ps_bootstrap_sync_repo() {
  local source_dir="${1}"
  ps_bootstrap_resolve_paths

  local required_paths=(
    "install.sh"
    "forward.sh"
    "lib/common.sh"
    "lib/launcher.sh"
    "templates/xray/base.json.tpl"
    "templates/singbox/base.json.tpl"
    "state/manifest.json"
    "README.md"
  )

  local required
  for required in "${required_paths[@]}"; do
    if [[ ! -e "${source_dir}/${required}" ]]; then
      ps_bootstrap_error "下载的项目不完整，缺少： ${required}"
      return 1
    fi
  done

  mkdir -p "${PS_BOOTSTRAP_INSTALL_DIR}"

  if [[ -f "${PS_BOOTSTRAP_INSTALL_DIR}/lib/common.sh" && "${PS_REMOTE_UPGRADE}" -eq 0 ]]; then
    ps_bootstrap_error "安装路径已存在 proxy-stack 项目： ${PS_BOOTSTRAP_INSTALL_DIR}"
    ps_bootstrap_error "请使用 --upgrade 更新已有安装。"
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
  ps_bootstrap_resolve_paths

  local archive_url="https://codeload.github.com/${PS_BOOTSTRAP_GH_USER}/${PS_BOOTSTRAP_GH_REPO}/tar.gz/${PS_BOOTSTRAP_GH_BRANCH}"
  local tmpdir
  tmpdir="$(mktemp -d)"
  local archive_file="${tmpdir}/repo.tar.gz"
  local extract_dir="${tmpdir}/extract"

  ps_bootstrap_info "正在下载项目归档： ${archive_url}"
  if ! curl -fsSL "${archive_url}" -o "${archive_file}"; then
    rm -rf "${tmpdir}"
    ps_bootstrap_error "下载失败： ${archive_url}"
    return 2
  fi

  if [[ ! -s "${archive_file}" ]]; then
    rm -rf "${tmpdir}"
    ps_bootstrap_error "下载归档为空。"
    return 2
  fi

  mkdir -p "${extract_dir}"
  if ! tar -xzf "${archive_file}" -C "${extract_dir}"; then
    rm -rf "${tmpdir}"
    ps_bootstrap_error "解压下载归档失败。"
    return 2
  fi

  local source_dir
  source_dir="$(find "${extract_dir}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ -z "${source_dir}" ]]; then
    rm -rf "${tmpdir}"
    ps_bootstrap_error "无法定位解压后的项目目录。"
    return 2
  fi

  ps_bootstrap_sync_repo "${source_dir}" || {
    rm -rf "${tmpdir}"
    return 2
  }

  rm -rf "${tmpdir}"
  ps_bootstrap_info "项目文件已同步到 ${PS_BOOTSTRAP_INSTALL_DIR}"
  ps_bootstrap_persist_repo_meta "${archive_url}"
  ps_bootstrap_install_launcher || return 2

  if [[ "${PS_BOOTSTRAP_ONLY}" -eq 1 ]]; then
    ps_bootstrap_info "仅引导模式已完成。"
    return 0
  fi

  local entry_script="install.sh"
  if [[ "${PS_MODE}" == "forward" ]]; then
    entry_script="forward.sh"
  fi

  if [[ ! -x "${PS_BOOTSTRAP_INSTALL_DIR}/${entry_script}" ]]; then
    ps_bootstrap_error "引导后缺少入口脚本： ${entry_script}"
    return 2
  fi

  ps_bootstrap_info "正在启动 ${entry_script}"
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
PS_LOCAL_REPO_MODE=1
ps_bootstrap_resolve_paths

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/logger.sh
source "${SCRIPT_DIR}/lib/logger.sh"
# shellcheck source=lib/launcher.sh
source "${SCRIPT_DIR}/lib/launcher.sh"
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
    ps_ui_error "操作失败： ${action}"
  fi
  ps_pause
}

ps_check_dependencies() {
  ps_ui_header "依赖检查"
  local required=(jq curl openssl tar sed awk grep)
  local optional=(systemctl ss journalctl base64)
  local cmd
  local missing=0

  for cmd in "${required[@]}"; do
    if ps_command_exists "${cmd}"; then
      printf "[OK] %s\n" "${cmd}"
    else
      if [[ "${cmd}" == "jq" ]]; then
        printf "[缺失] %s（manifest/state 运行必需）\n" "${cmd}"
      else
        printf "[缺失] %s\n" "${cmd}"
      fi
      missing=1
    fi
  done

  for cmd in "${optional[@]}"; do
    if ps_command_exists "${cmd}"; then
      printf "[OK] %s\n" "${cmd}"
    else
      printf "[警告] 可选工具缺失：%s\n" "${cmd}"
    fi
  done

  if [[ "${missing}" -ne 0 ]]; then
    ps_ui_error "依赖预检失败。"
    return 1
  fi

  ps_ui_success "依赖检查通过。"
  return 0
}

ps_preflight_checks() {
  if ! ps_check_dependencies; then
    if ! ps_command_exists jq; then
      ps_ui_error "受限：当前环境无法执行依赖 jq 的运行时校验/操作。"
      printf "修复命令（Debian/Ubuntu）： sudo apt-get update && sudo apt-get install -y jq\n"
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
    ps_ui_menu_select "卸载引擎" "返回" "请选择" \
      "卸载 xray-core" \
      "卸载 sing-box" \
      "卸载两者"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_xray_uninstall ;;
      2) ps_run_action ps_singbox_uninstall ;;
      3) ps_run_action ps_xray_uninstall; ps_run_action ps_singbox_uninstall ;;
      0) break ;;
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_menu_forwarding() {
  while true; do
    ps_ui_menu_select "转发管理" "返回" "请选择" \
      "查看转发条目" \
      "创建转发条目" \
      "删除转发条目" \
      "测试路由匹配"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_forward_list ;;
      2) ps_run_action ps_forward_create ;;
      3) ps_run_action ps_forward_delete ;;
      4) ps_run_action ps_route_test_match ;;
      0) break ;;
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_menu_stack_management() {
  while true; do
    ps_ui_menu_select "协议栈管理" "返回" "请选择" \
      "查看已安装协议栈" \
      "创建新协议栈" \
      "编辑协议栈" \
      "删除协议栈" \
      "启用/禁用协议栈" \
      "重新渲染配置"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_stack_list ;;
      2) ps_run_action ps_stack_create ;;
      3) ps_run_action ps_stack_edit ;;
      4) ps_run_action ps_stack_delete ;;
      5) ps_run_action ps_stack_toggle ;;
      6) ps_run_action ps_stack_rerender ;;
      0) break ;;
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_menu_inbound_management() {
  while true; do
    ps_ui_menu_select "入站管理" "返回" "请选择" \
      "查看入站" \
      "创建公网入站" \
      "创建本地入站" \
      "编辑入站" \
      "删除入站" \
      "绑定入站到协议栈"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_inbound_list ;;
      2) ps_run_action ps_inbound_create_public ;;
      3) ps_run_action ps_inbound_create_local ;;
      4) ps_run_action ps_inbound_edit ;;
      5) ps_run_action ps_inbound_delete ;;
      6) ps_run_action ps_inbound_bind_stack ;;
      0) break ;;
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_menu_outbound_routing() {
  while true; do
    ps_ui_menu_select "出站与路由" "返回" "请选择" \
      "查看出站" \
      "创建出站" \
      "编辑出站" \
      "删除出站" \
      "查看路由规则" \
      "创建路由规则" \
      "转发管理（独立模块）" \
      "调整路由优先级" \
      "测试路由匹配"

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
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_menu_cert_domain() {
  while true; do
    ps_ui_menu_select "证书与域名" "返回" "请选择" \
      "查看证书列表" \
      "申请证书（ACME）" \
      "安装自定义证书" \
      "配置自动续期" \
      "测试续期" \
      "管理 SNI / REALITY 握手参数"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_cert_list ;;
      2) ps_run_action ps_cert_issue_acme ;;
      3) ps_run_action ps_cert_install_custom ;;
      4) ps_run_action ps_cert_configure_auto_renew ;;
      5) ps_run_action ps_cert_test_renewal ;;
      6) ps_run_action ps_cert_manage_reality_params ;;
      0) break ;;
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_menu_subscribe_export() {
  while true; do
    ps_ui_menu_select "订阅与导出" "返回" "请选择" \
      "生成分享链接" \
      "生成 Base64 订阅" \
      "导出 Clash.Meta" \
      "导出 Xray 客户端配置" \
      "导出 sing-box 客户端配置" \
      "导出初始化规则包" \
      "导出客户端配置 + 初始化规则包" \
      "导出带路由的本地代理模板"

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
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_menu_logs_diagnostics() {
  while true; do
    ps_ui_menu_select "日志与诊断" "返回" "请选择" \
      "查看安装日志" \
      "查看 Xray 服务日志" \
      "查看 sing-box 服务日志" \
      "查看访问日志" \
      "查看错误日志" \
      "调整日志级别" \
      "切换 DNS 日志" \
      "配置日志轮转" \
      "导出诊断包" \
      "实时跟踪日志"

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
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_menu_engines_services() {
  while true; do
    ps_ui_menu_select "引擎与服务" "返回" "请选择" \
      "安装/升级 xray-core" \
      "安装/升级 sing-box" \
      "启动服务" \
      "停止服务" \
      "重启服务" \
      "重载配置" \
      "查看版本" \
      "卸载引擎" \
      "安装/更新 systemd 单元"

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
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_menu_backup_restore() {
  while true; do
    ps_ui_menu_select "备份与恢复" "返回" "请选择" \
      "备份 Manifest" \
      "备份配置文件" \
      "备份证书" \
      "恢复备份" \
      "回滚到上一版本"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_backup_manifest ;;
      2) ps_run_action ps_backup_configs ;;
      3) ps_run_action ps_backup_certificates ;;
      4) ps_run_action ps_backup_restore ;;
      5) ps_run_action ps_backup_rollback_previous ;;
      0) break ;;
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_handle_subcommand() {
  local subcommand="${1:-}"
  shift || true

  case "${subcommand}" in
    update)
      if [[ "${#}" -gt 0 ]]; then
        ps_ui_warn "update 忽略多余参数： $*"
      fi
      ps_bootstrap_resolve_repo_meta_for_update || return $?
      PS_REMOTE_UPGRADE=1
      PS_BOOTSTRAP_ONLY=1
      ps_bootstrap_from_github
      ;;
    export)
      ps_preflight_checks || return $?
      ps_init_manifest
      ps_sub_export_client_with_rules_bundle
      ;;
    doctor)
      ps_preflight_checks
      ;;
    logs)
      ps_preflight_checks || return $?
      ps_init_manifest
      ps_diag_view_install_log
      ;;
    info)
      ps_print_runtime_info
      ;;
    config)
      if [[ "${1:-}" != "repo" ]]; then
        ps_ui_error "不支持的 config 范围： ${1:-<empty>}"
        printf "用法： kprxy config repo --gh-user <user> --gh-repo <repo> --gh-branch <branch>\n"
        return 2
      fi
      ps_configure_repo_metadata
      ;;
    *)
      ps_ui_error "不支持的子命令： ${subcommand}"
      printf "支持的子命令：update、export、doctor、logs、info、config repo\n"
      return 2
      ;;
  esac
}

ps_print_runtime_info() {
  local meta_file
  meta_file="$(ps_bootstrap_meta_file)"
  printf "安装目录： %s\n" "${PS_BOOTSTRAP_INSTALL_DIR}"
  printf "Launcher: %s\n" "${PS_BOOTSTRAP_LAUNCHER_PATH}"
  printf "仓库元数据文件： %s\n" "${meta_file}"
  if [[ -f "${meta_file}" ]]; then
    printf "仓库元数据：\n"
    sed 's/^/  /' "${meta_file}"
  else
    printf "仓库元数据：<未配置>\n"
  fi
}

ps_configure_repo_metadata() {
  if ! ps_bootstrap_has_real_repo_meta "${PS_BOOTSTRAP_GH_USER}" "${PS_BOOTSTRAP_GH_REPO}" "${PS_BOOTSTRAP_GH_BRANCH}"; then
    ps_ui_error "无法从占位符保存仓库元数据。"
    printf "用法： kprxy config repo --gh-user <user> --gh-repo <repo> --gh-branch <branch>\n"
    return 2
  fi
  ps_bootstrap_persist_repo_meta "manual-config"
  ps_ui_success "仓库元数据已保存到 $(ps_bootstrap_meta_file)"
}

ps_ensure_local_launcher() {
  ps_bootstrap_resolve_paths
  ps_launcher_install "${SCRIPT_DIR}" "${PS_BOOTSTRAP_LAUNCHER_PATH}" "install.sh"
  if ! ps_launcher_verify "${PS_BOOTSTRAP_LAUNCHER_PATH}"; then
    ps_ui_warn "启动器校验失败： ${PS_BOOTSTRAP_LAUNCHER_PATH}"
    return 1
  fi
  ps_launcher_maybe_print_path_hint "${PS_BOOTSTRAP_LAUNCHER_PATH}" "$(ps_bootstrap_path_hint_marker)" "runtime"
}

main() {
  ps_prepare_runtime_dirs
  ps_logger_init
  ps_ensure_local_launcher || true

  if [[ "${PS_BOOTSTRAP_ONLY}" -eq 1 ]]; then
    ps_ui_info "检测到本地仓库模式，bootstrap-only 参数无效。"
    exit 0
  fi

  if [[ "${PS_REMOTE_UPGRADE}" -eq 1 ]]; then
    ps_ui_info "upgrade 参数用于远程引导，当前继续本地菜单模式。"
  fi

  if [[ "${#PS_RUNTIME_ARGS[@]}" -gt 0 ]]; then
    ps_handle_subcommand "${PS_RUNTIME_ARGS[0]}" "${PS_RUNTIME_ARGS[@]:1}"
    return $?
  fi

  ps_preflight_checks || exit $?
  ps_init_manifest

  if [[ "${PS_MODE}" == "forward" ]]; then
    ps_menu_forwarding
    ps_ui_info "已退出"
    exit 0
  fi

  while true; do
    ps_ui_menu_select "主菜单" "退出" "请选择" \
      "协议栈管理" \
      "入站管理" \
      "出站与路由" \
      "证书与域名" \
      "订阅与导出" \
      "日志与诊断" \
      "引擎与服务" \
      "备份与恢复"

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
        ps_ui_info "已退出"
        break
        ;;
      *)
        ps_ui_warn "选择无效"
        ps_pause
        ;;
    esac
  done
}

main "$@"
