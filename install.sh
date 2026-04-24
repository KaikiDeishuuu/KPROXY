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
kprxy 安装器/控制台

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
  service-wizard             一步式创建服务（自动完成模板+入口绑定）
  export                     一键导出：客户端配置 + 初始化规则包（推荐给普通用户）
  doctor                     执行依赖预检
  status                     查看运行状态（summary/engine/cert/conflict/traffic/reality）
  uninstall                  卸载 kprxy（默认保留数据，可选 --purge / --keep-data / --yes）
  cleanup                    清理临时与生成产物（可选 --yes）
  reset                      重置项目状态与配置（保留框架安装，可选 --yes）
  repair-launcher            显式修复/更新 kprxy 启动命令
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
        [[ $# -gt 0 ]] || { printf '%s\n' "--install-dir 缺少参数值" >&2; exit 2; }
        PS_BOOTSTRAP_INSTALL_DIR="$1"
        PS_BOOTSTRAP_INSTALL_DIR_EXPLICIT=1
        ;;
      --gh-user)
        shift
        [[ $# -gt 0 ]] || { printf '%s\n' "--gh-user 缺少参数值" >&2; exit 2; }
        PS_BOOTSTRAP_GH_USER="$1"
        PS_BOOTSTRAP_GH_USER_EXPLICIT=1
        ;;
      --gh-repo)
        shift
        [[ $# -gt 0 ]] || { printf '%s\n' "--gh-repo 缺少参数值" >&2; exit 2; }
        PS_BOOTSTRAP_GH_REPO="$1"
        PS_BOOTSTRAP_GH_REPO_EXPLICIT=1
        ;;
      --gh-branch)
        shift
        [[ $# -gt 0 ]] || { printf '%s\n' "--gh-branch 缺少参数值" >&2; exit 2; }
        PS_BOOTSTRAP_GH_BRANCH="$1"
        PS_BOOTSTRAP_GH_BRANCH_EXPLICIT=1
        ;;
      --mode)
        shift
        [[ $# -gt 0 ]] || { printf '%s\n' "--mode 缺少参数值" >&2; exit 2; }
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

ps_bootstrap_copy_file_atomic() {
  local source_file="${1}"
  local target_file="${2}"
  local tmp_file=""

  tmp_file="$(mktemp "${target_file}.tmp.XXXXXX")" || return 1
  if ! cp -a "${source_file}" "${tmp_file}"; then
    rm -f "${tmp_file}"
    return 1
  fi

  if ! mv -f "${tmp_file}" "${target_file}"; then
    rm -f "${tmp_file}"
    return 1
  fi
}

ps_bootstrap_sync_repo() {
  local source_dir="${1}"
  ps_bootstrap_resolve_paths

  local required_paths=(
    "install.sh"
    "forward.sh"
    "lib/common.sh"
    "lib/status.sh"
    "lib/uninstall.sh"
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
    ps_bootstrap_error "安装路径已存在 kprxy 项目： ${PS_BOOTSTRAP_INSTALL_DIR}"
    ps_bootstrap_error "请使用 --upgrade 更新已有安装。"
    return 1
  fi

  rm -rf "${PS_BOOTSTRAP_INSTALL_DIR}/lib" "${PS_BOOTSTRAP_INSTALL_DIR}/templates" "${PS_BOOTSTRAP_INSTALL_DIR}/scripts"
  cp -a "${source_dir}/lib" "${PS_BOOTSTRAP_INSTALL_DIR}/lib"
  cp -a "${source_dir}/templates" "${PS_BOOTSTRAP_INSTALL_DIR}/templates"
  if [[ -d "${source_dir}/scripts" ]]; then
    cp -a "${source_dir}/scripts" "${PS_BOOTSTRAP_INSTALL_DIR}/scripts"
  fi
  ps_bootstrap_copy_file_atomic "${source_dir}/install.sh" "${PS_BOOTSTRAP_INSTALL_DIR}/install.sh" || {
    ps_bootstrap_error "同步 install.sh 失败。"
    return 1
  }
  cp -a "${source_dir}/forward.sh" "${PS_BOOTSTRAP_INSTALL_DIR}/forward.sh"
  cp -a "${source_dir}/README.md" "${PS_BOOTSTRAP_INSTALL_DIR}/README.md"

  mkdir -p "${PS_BOOTSTRAP_INSTALL_DIR}/state" "${PS_BOOTSTRAP_INSTALL_DIR}/output" "${PS_BOOTSTRAP_INSTALL_DIR}/backups"
  if [[ ! -f "${PS_BOOTSTRAP_INSTALL_DIR}/state/manifest.json" ]]; then
    cp -a "${source_dir}/state/manifest.json" "${PS_BOOTSTRAP_INSTALL_DIR}/state/manifest.json"
  fi

  chmod +x "${PS_BOOTSTRAP_INSTALL_DIR}/install.sh" "${PS_BOOTSTRAP_INSTALL_DIR}/forward.sh"
  if [[ -d "${PS_BOOTSTRAP_INSTALL_DIR}/scripts" ]]; then
    find "${PS_BOOTSTRAP_INSTALL_DIR}/scripts" -type f -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true
  fi
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
# shellcheck source=lib/status.sh
source "${SCRIPT_DIR}/lib/status.sh"
# shellcheck source=lib/uninstall.sh
source "${SCRIPT_DIR}/lib/uninstall.sh"

ps_run_action() {
  local action="${1}"
  shift || true

  if ! "${action}" "$@"; then
    ps_ui_error "操作失败： ${action}"
  fi

  if [[ "${PS_SESSION_TERMINATE_AFTER_ACTION:-0}" == "1" ]]; then
    if [[ -n "${PS_SESSION_TERMINATE_REASON:-}" ]]; then
      ps_ui_warn "${PS_SESSION_TERMINATE_REASON}"
    else
      ps_ui_warn "当前会话即将退出。"
    fi
    ps_ui_tip "如需重新安装，请重新执行安装命令（或在仓库内运行 install.sh update）。"
    exit 0
  fi

  ps_pause
}

ps_show_next_steps() {
  local tips=("$@")
  [[ "${#tips[@]}" -gt 0 ]] || return 0
  printf "\n下一步建议：\n"
  local tip
  for tip in "${tips[@]}"; do
    printf -- "- %s\n" "${tip}"
  done
}

ps_service_stack_engine() {
  local stack_id="${1:-}"
  [[ -n "${stack_id}" ]] || return 1
  jq -r --arg sid "${stack_id}" '.stacks[] | select(.stack_id == $sid) | .engine // "xray"' "${PS_MANIFEST}"
}

PS_SERVICE_WIZARD_RUNTIME_OK=0
PS_SERVICE_WIZARD_RUNTIME_MESSAGE=""

ps_service_runtime_result() {
  local ok="${1:-0}"
  local message="${2:-}"
  PS_SERVICE_WIZARD_RUNTIME_OK="${ok}"
  PS_SERVICE_WIZARD_RUNTIME_MESSAGE="${message}"
}

ps_service_ensure_engine_binary() {
  local engine="${1:-xray}"
  case "${engine}" in
    xray)
      if [[ -x "$(ps_engine_binary xray)" ]]; then
        return 0
      fi
      ps_ui_info "检测到 xray-core 尚未安装，正在安装 kprxy 私有二进制..."
      ps_xray_install_upgrade || {
        ps_ui_warn "xray-core 自动安装失败，请稍后在“核心与运行控制”中重试。"
        return 1
      }
      ;;
    singbox)
      if [[ -x "$(ps_engine_binary singbox)" ]]; then
        return 0
      fi
      ps_ui_info "检测到 sing-box 尚未安装，正在安装 kprxy 私有二进制..."
      ps_singbox_install_upgrade || {
        ps_ui_warn "sing-box 自动安装失败，请稍后在“核心与运行控制”中重试。"
        return 1
      }
      ;;
    *)
      ps_ui_warn "未知引擎：${engine}，跳过自动安装。"
      return 1
      ;;
  esac
}

ps_service_try_start_engine() {
  local engine="${1:-xray}"
  local service label
  service="$(ps_engine_service_name "${engine}")"
  label="Xray"
  if [[ "${engine}" == "singbox" ]]; then label="sing-box"; fi

  if ! ps_systemd_is_available; then
    ps_ui_warn "未检测到 systemd，已完成配置渲染，请手动启动 ${label}。"
    return 1
  fi
  if ! ps_is_root; then
    ps_ui_warn "当前非 root，已完成配置渲染，请手动启动 ${label} 服务。"
    return 1
  fi

  ps_systemd_install_units "${engine}" || {
    ps_ui_warn "systemd 单元安装失败，请在“核心与运行控制”中检查。"
    return 1
  }

  if ps_systemd_service_action restart "${service}"; then
    ps_log_success "${label} 服务已自动启动：${service}.service"
    return 0
  fi

  ps_ui_warn "${label} 服务自动启动失败，请在“核心与运行控制”中检查。"
  return 1
}

ps_service_render_engine() {
  local engine="${1:-xray}"
  case "${engine}" in
    xray)
      ps_render_xray_config
      ;;
    singbox)
      ps_render_singbox_config
      ;;
    *)
      ps_ui_warn "未知引擎：${engine}，跳过自动渲染。"
      return 1
      ;;
  esac
}

ps_service_explain_protocol_certificate_behavior() {
  local stack_id="${1:-}"
  [[ -n "${stack_id}" ]] || return 0

  local protocol security domain cert_mode
  protocol="$(jq -r --arg sid "${stack_id}" '.stacks[] | select(.stack_id == $sid) | .protocol // "vless"' "${PS_MANIFEST}")"
  security="$(jq -r --arg sid "${stack_id}" '.stacks[] | select(.stack_id == $sid) | .security // "none"' "${PS_MANIFEST}")"
  domain="$(jq -r --arg sid "${stack_id}" '.stacks[] | select(.stack_id == $sid) | (.tls.domain // .server // "")' "${PS_MANIFEST}")"
  cert_mode="$(jq -r --arg sid "${stack_id}" '.stacks[] | select(.stack_id == $sid) | .tls_cert_mode // "none"' "${PS_MANIFEST}")"

  if [[ "${security}" == "tls" ]]; then
    ps_ui_info "服务类型：${protocol} + TLS，需要证书。域名：${domain:-未设置}，证书模式：${cert_mode}。"
    return 0
  fi

  if [[ "${security}" == "reality" ]]; then
    ps_ui_info "服务类型：${protocol} + REALITY，默认不要求为节点域名签发 TLS 证书。"
    return 0
  fi
}

ps_service_prepare_tls_material() {
  local stack_id="${1:-}"
  [[ -n "${stack_id}" ]] || return 1

  local security cert_mode domain acme_email
  security="$(jq -r --arg sid "${stack_id}" '.stacks[] | select(.stack_id == $sid) | .security // "none"' "${PS_MANIFEST}")"
  if [[ "${security}" != "tls" ]]; then
    return 0
  fi

  cert_mode="$(jq -r --arg sid "${stack_id}" '.stacks[] | select(.stack_id == $sid) | .tls_cert_mode // "manual"' "${PS_MANIFEST}")"
  domain="$(jq -r --arg sid "${stack_id}" '.stacks[] | select(.stack_id == $sid) | (.tls.domain // .server // "")' "${PS_MANIFEST}")"
  acme_email="$(jq -r --arg sid "${stack_id}" '.stacks[] | select(.stack_id == $sid) | (.tls.acme_email // "")' "${PS_MANIFEST}")"

  if [[ -z "${domain}" ]]; then
    ps_ui_warn "TLS 服务缺少域名，无法自动准备证书。"
    return 1
  fi

  if ps_cert_bind_domain_to_stack "${stack_id}" "${domain}"; then
    ps_log_info "已复用现有证书并绑定到服务：${domain}"
    return 0
  fi

  if [[ "${cert_mode}" != "acme" ]]; then
    ps_ui_warn "TLS 证书模式为 ${cert_mode}，当前未检测到可用证书，请先在“证书与域名”中配置证书。"
    return 1
  fi

  ps_ui_info "检测到 TLS + ACME，正在自动申请证书：${domain}"
  if ! ps_cert_issue_acme_auto_domain "${domain}" "${acme_email}"; then
    ps_ui_warn "自动申请证书失败，服务定义已保存但不会应用到运行配置。"
    return 1
  fi

  if ! ps_cert_bind_domain_to_stack "${stack_id}" "${domain}"; then
    ps_ui_warn "证书已签发，但绑定到服务失败，请在“证书与域名”中检查。"
    return 1
  fi

  ps_log_success "TLS 证书已自动绑定到服务：${domain}"
  return 0
}

ps_service_finalize_runtime() {
  local stack_id="${1:-}"
  local engine
  engine="$(ps_service_stack_engine "${stack_id}")"
  [[ -n "${engine}" ]] || engine="xray"

  if ! ps_service_ensure_engine_binary "${engine}"; then
    ps_service_runtime_result 0 "私有内核安装失败"
    return 1
  fi

  ps_service_explain_protocol_certificate_behavior "${stack_id}" || true

  if ! ps_service_prepare_tls_material "${stack_id}"; then
    ps_service_runtime_result 0 "TLS 证书未就绪"
    ps_ui_warn "新服务定义已写入状态文件，但 TLS 证书未就绪，未应用到当前运行配置。"
    return 1
  fi

  if ! ps_service_render_engine "${engine}"; then
    ps_service_runtime_result 0 "配置渲染或校验失败"
    ps_ui_warn "新服务定义已写入状态文件，但未应用到当前运行配置。"
    ps_ui_warn "当前仍保留旧配置继续运行，新端口在修复前不会监听。"
    ps_ui_warn "请前往“运行状态与诊断”查看渲染/校验详情。"
    return 1
  fi

  if ! ps_service_try_start_engine "${engine}"; then
    ps_service_runtime_result 0 "服务启动失败"
    return 1
  fi

  ps_service_runtime_result 1 "服务已创建并成功启动"
  return 0
}

ps_service_create_bind_public_inbound() {
  local stack_id="${1:-}"
  local stack_protocol="${2:-}"
  local stack_port="${3:-0}"
  [[ -n "${stack_id}" ]] || return 1

  local exists
  exists="$(jq -r --arg sid "${stack_id}" '.inbounds | any(.stack_id == $sid and .public == true)' "${PS_MANIFEST}")"
  if [[ "${exists}" == "true" ]]; then
    ps_log_info "该服务已存在绑定的公网监听入口，跳过自动创建。"
    return 0
  fi

  local tag_base tag suffix
  tag_base="svc-${stack_id}"
  tag="${tag_base}"
  suffix=1
  while ps_manifest_array_has '.inbounds' 'tag' "${tag}"; do
    tag="${tag_base}-${suffix}"
    suffix=$((suffix + 1))
  done

  local inbound_json
  inbound_json="$(jq -n \
    --arg tag "${tag}" \
    --arg type "${stack_protocol}" \
    --arg listen "0.0.0.0" \
    --argjson port "${stack_port}" \
    --arg stack_id "${stack_id}" \
    --arg created_at "$(ps_now_iso)" \
    '{tag:$tag,type:$type,listen:$listen,port:$port,auth:{},udp:true,stack_id:$stack_id,public:true,enabled:true,managed_by:"service-wizard",created_at:$created_at,updated_at:$created_at}')"

  ps_manifest_update --argjson inbound "${inbound_json}" --arg ts "$(ps_now_iso)" '.inbounds += [$inbound] | .meta.updated_at = $ts'
  ps_log_success "已自动创建并绑定公网监听入口：${tag}"
}

ps_service_rollback_wizard_artifacts() {
  local stack_id="${1:-}"
  [[ -n "${stack_id}" ]] || return 1

  local stack_count inbound_count
  stack_count="$(jq -r --arg sid "${stack_id}" '[.stacks[]? | select(.stack_id == $sid)] | length' "${PS_MANIFEST}" 2>/dev/null || printf '0')"
  inbound_count="$(jq -r --arg sid "${stack_id}" '[.inbounds[]? | select(.stack_id == $sid)] | length' "${PS_MANIFEST}" 2>/dev/null || printf '0')"

  ps_manifest_update \
    --arg sid "${stack_id}" \
    --arg ts "$(ps_now_iso)" \
    '.stacks |= map(select(.stack_id != $sid)) | .inbounds |= map(select(.stack_id != $sid)) | .meta.updated_at = $ts'

  ps_ui_warn "已回滚本次未完成创建：移除协议栈 ${stack_id}，清理关联入口 ${inbound_count} 条。"
  if [[ "${stack_count}" == "0" ]]; then
    ps_ui_warn "回滚时未检测到可移除的协议栈记录 ：${stack_id}"
  fi
  return 0
}

ps_service_wizard() {
  ps_print_header "一步式创建服务"
  ps_ui_tip "将自动完成：协议模板创建 + 公网监听入口绑定。"
  ps_service_runtime_result 0 ""

  # REALITY key generation requires xray x25519. Ensure xray is available
  # before ps_stack_create runs, so the keypair step does not fail on fresh
  # installs where xray has not been downloaded yet.
  if ! ps_service_ensure_engine_binary xray; then
    ps_service_runtime_result 0 "xray-core 安装失败（REALITY 密钥生成需要 xray x25519）"
    return 1
  fi

  local before_ids after_ids new_stack_id
  before_ids="$(jq -r '.stacks[]?.stack_id' "${PS_MANIFEST}" | tr '\n' ' ')"

  if ! ps_stack_create; then
    if [[ "${PS_STACK_CREATE_ABORTED:-0}" == "1" ]]; then
      ps_service_runtime_result 0 "${PS_STACK_CREATE_ABORT_REASON:-用户已取消创建}"
      return 2
    fi
    ps_service_runtime_result 0 "${PS_STACK_CREATE_ABORT_REASON:-协议栈创建失败}"
    return 1
  fi

  after_ids="$(jq -r '.stacks[]?.stack_id' "${PS_MANIFEST}" | tr '\n' ' ')"
  new_stack_id="$(jq -r --arg before "${before_ids}" '
    .stacks
    | map(.stack_id)
    | map(select(($before | split(" ")) | index(.) | not))
    | last // empty
  ' "${PS_MANIFEST}")"

  if [[ -z "${new_stack_id}" ]]; then
    new_stack_id="$(jq -r '.stacks | sort_by(.created_at // "") | last.stack_id // empty' "${PS_MANIFEST}")"
  fi
  [[ -n "${new_stack_id}" ]] || return 1

  local stack_protocol stack_port
  stack_protocol="$(jq -r --arg sid "${new_stack_id}" '.stacks[] | select(.stack_id == $sid) | .protocol // "vless"' "${PS_MANIFEST}")"
  stack_port="$(jq -r --arg sid "${new_stack_id}" '.stacks[] | select(.stack_id == $sid) | .port // 0' "${PS_MANIFEST}")"

  if ! ps_service_create_bind_public_inbound "${new_stack_id}" "${stack_protocol}" "${stack_port}"; then
    ps_service_runtime_result 0 "公网入口绑定失败"
    ps_service_rollback_wizard_artifacts "${new_stack_id}" || true
    return 1
  fi

  if ! ps_service_finalize_runtime "${new_stack_id}"; then
    local failed_reason="${PS_SERVICE_WIZARD_RUNTIME_MESSAGE:-运行链路失败}"
    ps_service_rollback_wizard_artifacts "${new_stack_id}" || true
    ps_service_runtime_result 0 "${failed_reason}（已自动回滚）"
    return 1
  fi

  return 0
}

ps_action_create_service() {
  local wizard_rc=0
  ps_service_wizard || wizard_rc=$?
  if [[ "${wizard_rc}" -eq 2 ]]; then
    printf "\n已取消创建\n"
    printf "原因：%s\n" "${PS_SERVICE_WIZARD_RUNTIME_MESSAGE:-用户已取消}"
    ps_show_next_steps \
      "可重新执行“一步式创建服务”并调整参数" \
      "前往“运行状态与诊断”确认当前服务不受影响"
    return 0
  fi
  if [[ "${wizard_rc}" -ne 0 ]]; then
    printf "\n创建失败\n"
    printf "原因：%s\n" "${PS_SERVICE_WIZARD_RUNTIME_MESSAGE:-协议栈创建失败}"
    ps_show_next_steps \
      "修复后重新执行“一步式创建服务”" \
      "前往“运行状态与诊断”查看最近渲染失败信息"
    return 1
  fi
  local stack_info
  stack_info="$(jq -r '.stacks | if length==0 then "" else (sort_by(.created_at // "") | last | "名称：\(.name // "-") | 协议：\(.protocol // "-") | 安全：\(.security // "-") | 地址：\(.server // "-") | 端口：\(.port // "-")") end' "${PS_MANIFEST}")"
  if [[ -n "${stack_info}" ]]; then printf "\n创建完成\n%s\n" "${stack_info}"; fi
  if [[ "${PS_SERVICE_WIZARD_RUNTIME_OK:-0}" == "1" ]]; then
    printf "状态：已生成并启用（含自动入口绑定）\n"
    ps_show_next_steps \
      "前往“订阅与导出”生成客户端配置" \
      "前往“运行状态与诊断”检查监听与配置状态"
  else
    printf "状态：服务定义已创建，但未完成运行链路（%s）\n" "${PS_SERVICE_WIZARD_RUNTIME_MESSAGE:-原因未知}"
    printf "说明：服务记录已写入 state/manifest，但未应用到当前运行配置。\n"
    printf "说明：系统继续运行旧配置；新端口在修复前不会监听。\n"
    ps_show_next_steps \
      "前往“运行状态与诊断”查看渲染/校验详情" \
      "前往“核心与运行控制”检查内核安装与服务启动"
  fi
}

ps_action_create_protocol_template() {
  ps_stack_create || return 1
  printf "\n高级提示\n"
  printf "协议模板已创建。该模板定义协议/加密/传输参数，不直接代表本地代理入口。\n"
  ps_show_next_steps \
    "前往“高级设置 -> 监听入口管理（高级）”绑定监听端口" \
    "或返回“创建与管理服务”继续走推荐流程"
}

ps_action_create_local_proxy_entry() {
  ps_inbound_create_local || return 1
  local inbound_info
  inbound_info="$(jq -r '.inbounds | map(select(.public != true)) | if length==0 then "" else (sort_by(.created_at // "") | last | "标签：\(.tag) | 类型：\(.type) | 监听：\(.listen):\(.port)") end' "${PS_MANIFEST}")"
  if [[ -n "${inbound_info}" ]]; then printf "\n创建完成\n%s\n" "${inbound_info}"; fi
  ps_show_next_steps \
    "如需链式代理，请前往“本地代理与转发”创建转发链" \
    "如需按域名/IP 精细分流，请前往“路由与规则”创建路由规则"
}

ps_action_issue_cert() {
  ps_cert_issue_acme || return 1
  ps_show_next_steps \
    "若服务使用 TLS，可前往“创建与管理服务”检查域名绑定" \
    "前往“运行状态与诊断”确认证书状态与有效期"
}

ps_action_export_bundle() {
  ps_sub_export_client_with_rules_bundle || return 1
  ps_show_next_steps \
    "将生成结果分发到客户端后，可在“运行状态与诊断”观察服务与端口状态"
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

  if ps_command_exists unzip || ps_command_exists bsdtar; then
    if ps_command_exists unzip; then
      printf "[OK] %s\n" "unzip"
    else
      printf "[OK] %s\n" "bsdtar"
    fi
  else
    printf "[缺失] %s\n" "unzip 或 bsdtar（xray-core 自动安装所需）"
    missing=1
  fi

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
    ps_ui_menu_select_with_hint "高级绑定/编排" "面向高级用户：手动维护转发链与路由绑定关系。" "返回" "请选择" \
      "查看转发链" \
      "创建转发链" \
      "编辑转发链" \
      "启用/禁用转发链" \
      "删除转发链" \
      "查看绑定诊断" \
      "测试路由匹配"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_forward_list ;;
      2) ps_run_action ps_forward_create ;;
      3) ps_run_action ps_forward_edit ;;
      4) ps_run_action ps_forward_toggle ;;
      5) ps_run_action ps_forward_delete ;;
      6) ps_run_action ps_forward_inspect_health ;;
      7) ps_run_action ps_route_test_match ;;
      0) break ;;
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_menu_advanced_stack_templates() {
  while true; do
    ps_ui_menu_select_with_hint "协议模板管理（高级）" "定义协议、加密和传输参数。该层不直接解释业务场景，面向高级用户。" "返回" "请选择" \
      "查看协议模板列表" \
      "创建协议模板" \
      "编辑协议模板" \
      "删除协议模板" \
      "启用/禁用协议模板" \
      "重新渲染运行配置"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_stack_list ;;
      2) ps_run_action ps_action_create_protocol_template ;;
      3) ps_run_action ps_stack_edit ;;
      4) ps_run_action ps_stack_delete ;;
      5) ps_run_action ps_stack_toggle ;;
      6) ps_run_action ps_stack_rerender ;;
      0) break ;;
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_menu_advanced_inbound_management() {
  while true; do
    ps_ui_menu_select_with_hint "监听入口管理（高级）" "定义监听端口与入口类型，可手动绑定到协议模板。" "返回" "请选择" \
      "查看监听入口" \
      "创建公网监听入口" \
      "创建本地监听入口" \
      "编辑监听入口" \
      "删除监听入口" \
      "手动绑定到协议模板"

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

ps_menu_advanced_outbound_routing() {
  while true; do
    ps_ui_menu_select_with_hint "高级绑定/编排（高级）" "面向需要精细控制链路策略的用户。" "返回" "请选择" \
      "查看上游出口" \
      "创建上游出口" \
      "编辑上游出口" \
      "删除上游出口" \
      "查看路由规则" \
      "创建路由规则" \
      "编辑路由规则" \
      "启用/禁用路由规则" \
      "删除路由规则" \
      "路由上移" \
      "路由下移" \
      "调整路由优先级（手动）" \
      "转发管理（高级）" \
      "测试路由匹配"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_outbound_list ;;
      2) ps_run_action ps_outbound_create ;;
      3) ps_run_action ps_outbound_edit ;;
      4) ps_run_action ps_outbound_delete ;;
      5) ps_run_action ps_route_list ;;
      6) ps_run_action ps_route_create_rule ;;
      7) ps_run_action ps_route_edit_rule ;;
      8) ps_run_action ps_route_toggle_rule ;;
      9) ps_run_action ps_route_delete_rule ;;
      10) ps_run_action ps_route_move_up ;;
      11) ps_run_action ps_route_move_down ;;
      12) ps_run_action ps_route_reorder_priority ;;
      13) ps_menu_forwarding ;;
      14) ps_run_action ps_route_test_match ;;
      0) break ;;
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_menu_service_management() {
  while true; do
    ps_ui_menu_select_with_hint "创建与管理服务" "创建对外可用的代理服务（如 VLESS/REALITY、Shadowsocks 2022）。" "返回" "请选择" \
      "查看服务列表" \
      "一步式创建服务（推荐）" \
      "编辑服务参数" \
      "删除服务" \
      "启用/禁用服务" \
      "重新渲染服务配置"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_stack_list ;;
      2) ps_run_action ps_action_create_service ;;
      3) ps_run_action ps_stack_edit ;;
      4) ps_run_action ps_stack_delete ;;
      5) ps_run_action ps_stack_toggle ;;
      6) ps_run_action ps_stack_rerender ;;
      0) break ;;
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_menu_local_proxy_forward() {
  while true; do
    ps_ui_menu_select_with_hint "本地代理与转发" "创建本地入口与转发链，让流量进入你定义的上游出口。" "返回" "请选择" \
      "查看本地代理入口" \
      "创建本地代理入口（推荐）" \
      "编辑本地代理入口" \
      "删除本地代理入口" \
      "创建转发链（推荐）" \
      "查看转发链" \
      "编辑转发链" \
      "启用/禁用转发链" \
      "删除转发链" \
      "查看绑定诊断"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_inbound_list_local_only ;;
      2) ps_run_action ps_action_create_local_proxy_entry ;;
      3) ps_run_action ps_inbound_edit ;;
      4) ps_run_action ps_inbound_delete ;;
      5) ps_run_action ps_forward_create ;;
      6) ps_run_action ps_forward_list ;;
      7) ps_run_action ps_forward_edit ;;
      8) ps_run_action ps_forward_toggle ;;
      9) ps_run_action ps_forward_delete ;;
      10) ps_run_action ps_forward_inspect_health ;;
      0) break ;;
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_menu_upstream_outbound() {
  while true; do
    ps_ui_menu_select_with_hint "上游代理与出口" "管理 direct/block/dns 及各类远端上游代理。" "返回" "请选择" \
      "查看上游出口" \
      "创建上游出口" \
      "编辑上游出口" \
      "删除上游出口" \
      "查看绑定诊断"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_outbound_list ;;
      2) ps_run_action ps_outbound_create ;;
      3) ps_run_action ps_outbound_edit ;;
      4) ps_run_action ps_outbound_delete ;;
      5) ps_run_action ps_forward_inspect_health ;;
      0) break ;;
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_menu_route_rules() {
  while true; do
    ps_ui_menu_select_with_hint "路由与规则" "按入口/域名/IP/网络绑定流量到指定上游出口。" "返回" "请选择" \
      "查看路由规则" \
      "创建路由规则" \
      "编辑路由规则" \
      "启用/禁用路由规则" \
      "删除路由规则" \
      "路由上移" \
      "路由下移" \
      "调整路由优先级（手动）" \
      "测试路由匹配"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_route_list ;;
      2) ps_run_action ps_route_create_rule ;;
      3) ps_run_action ps_route_edit_rule ;;
      4) ps_run_action ps_route_toggle_rule ;;
      5) ps_run_action ps_route_delete_rule ;;
      6) ps_run_action ps_route_move_up ;;
      7) ps_run_action ps_route_move_down ;;
      8) ps_run_action ps_route_reorder_priority ;;
      9) ps_run_action ps_route_test_match ;;
      0) break ;;
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_menu_cert_domain() {
  while true; do
    ps_ui_menu_select_with_hint "证书与域名" "管理 TLS 证书、自动续费和服务域名。" "返回" "请选择" \
      "查看证书列表" \
      "申请证书（ACME）" \
      "安装自定义证书" \
      "配置自动续期" \
      "测试续期" \
      "管理 SNI / REALITY 握手参数"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_cert_list ;;
      2) ps_run_action ps_action_issue_cert ;;
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
    ps_ui_menu_select_with_hint "订阅与导出" "生成客户端可直接使用的配置与初始化规则。" "返回" "请选择" \
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
      7) ps_run_action ps_action_export_bundle ;;
      8) ps_run_action ps_sub_export_local_proxy_templates ;;
      0) break ;;
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_menu_logs_diagnostics() {
  while true; do
    ps_ui_menu_select_with_hint "运行状态与诊断" "查看状态、日志与诊断信息，定位运行问题。" "返回" "请选择" \
      "查看完整运行状态" \
      "仅查看内核/进程状态" \
      "仅查看证书状态" \
      "仅查看冲突检测" \
      "仅查看转发/路由健康" \
      "仅查看 VLESS-REALITY 诊断" \
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
      1) ps_run_action ps_status_command summary ;;
      2) ps_run_action ps_status_command engine ;;
      3) ps_run_action ps_status_command cert ;;
      4) ps_run_action ps_status_command conflict ;;
      5) ps_run_action ps_status_command traffic ;;
      6) ps_run_action ps_status_command reality ;;
      7) ps_run_action ps_diag_view_install_log ;;
      8) ps_run_action ps_diag_view_xray_service_log ;;
      9) ps_run_action ps_diag_view_singbox_service_log ;;
      10) ps_run_action ps_diag_view_access_log ;;
      11) ps_run_action ps_diag_view_error_log ;;
      12) ps_run_action ps_diag_change_log_level ;;
      13) ps_run_action ps_diag_toggle_dns_logging ;;
      14) ps_run_action ps_diag_configure_log_rotation ;;
      15) ps_run_action ps_diag_export_bundle ;;
      16) ps_run_action ps_diag_tail_logs ;;
      0) break ;;
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_menu_engines_services() {
  while true; do
    ps_ui_menu_select_with_hint "核心与运行控制" "管理 Xray/sing-box 核心与运行服务。" "返回" "请选择" \
      "安装/升级 Xray 核心" \
      "安装/升级 sing-box 核心" \
      "启动服务" \
      "停止服务" \
      "重启服务" \
      "重载配置" \
      "查看核心版本" \
      "移除核心二进制" \
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
    ps_ui_menu_select_with_hint "备份、清理与卸载" "执行备份、重置、清理与卸载等生命周期操作。" "返回" "请选择" \
      "备份 Manifest" \
      "备份配置文件" \
      "备份证书" \
      "恢复备份" \
      "回滚到上一版本" \
      "卸载 kprxy（保留数据）" \
      "完全清理卸载（Purge）" \
      "清理临时文件" \
      "重置项目状态"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_run_action ps_backup_manifest ;;
      2) ps_run_action ps_backup_configs ;;
      3) ps_run_action ps_backup_certificates ;;
      4) ps_run_action ps_backup_restore ;;
      5) ps_run_action ps_backup_rollback_previous ;;
      6) ps_run_action ps_lifecycle_uninstall keep-data ;;
      7) ps_run_action ps_lifecycle_uninstall purge ;;
      8) ps_run_action ps_lifecycle_cleanup ;;
      9) ps_run_action ps_lifecycle_reset ;;
      0) break ;;
      *) ps_ui_warn "选择无效"; ps_pause ;;
    esac
  done
}

ps_menu_advanced_settings() {
  while true; do
    ps_ui_menu_select_with_hint "高级设置" "面向高级用户的模板、监听入口与高级编排功能。" "返回" "请选择" \
      "协议模板管理（高级）" \
      "监听入口管理（高级）" \
      "出站与高级路由（高级）"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_menu_advanced_stack_templates ;;
      2) ps_menu_advanced_inbound_management ;;
      3) ps_menu_advanced_outbound_routing ;;
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
    service-wizard)
      ps_preflight_checks || return $?
      ps_init_manifest
      ps_service_wizard
      ;;
    export)
      ps_preflight_checks || return $?
      ps_init_manifest
      ps_sub_export_client_with_rules_bundle
      ;;
    doctor)
      ps_preflight_checks
      ;;
    status)
      ps_preflight_checks || return $?
      ps_init_manifest
      ps_status_command "${1:-summary}"
      ;;
    uninstall)
      local uninstall_mode="keep-data"
      PS_LIFECYCLE_ASSUME_YES=0
      while [[ "${#}" -gt 0 ]]; do
        case "${1}" in
          --purge) uninstall_mode="purge" ;;
          --keep-data) uninstall_mode="keep-data" ;;
          --yes|-y) PS_LIFECYCLE_ASSUME_YES=1 ;;
          *)
            ps_ui_error "不支持的 uninstall 参数：${1}"
            printf "用法： kprxy uninstall [--purge|--keep-data] [--yes]\n"
            return 2
            ;;
        esac
        shift || true
      done
      ps_lifecycle_uninstall "${uninstall_mode}"
      ;;
    cleanup)
      PS_LIFECYCLE_ASSUME_YES=0
      while [[ "${#}" -gt 0 ]]; do
        case "${1}" in
          --yes|-y) PS_LIFECYCLE_ASSUME_YES=1 ;;
          *)
            ps_ui_error "不支持的 cleanup 参数：${1}"
            printf "用法： kprxy cleanup [--yes]\n"
            return 2
            ;;
        esac
        shift || true
      done
      ps_lifecycle_cleanup
      ;;
    reset)
      PS_LIFECYCLE_ASSUME_YES=0
      while [[ "${#}" -gt 0 ]]; do
        case "${1}" in
          --yes|-y) PS_LIFECYCLE_ASSUME_YES=1 ;;
          *)
            ps_ui_error "不支持的 reset 参数：${1}"
            printf "用法： kprxy reset [--yes]\n"
            return 2
            ;;
        esac
        shift || true
      done
      ps_lifecycle_reset
      ;;
    repair-launcher)
      ps_repair_launcher
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
      printf '%s\n' "支持的子命令：update、service-wizard（一步式创建服务）、export、doctor、status、uninstall、cleanup、reset、logs、info、config repo、repair-launcher"
      return 2
      ;;
  esac
}

ps_print_runtime_info() {
  local meta_file
  meta_file="$(ps_bootstrap_meta_file)"
  printf '%s\n' "安装目录： ${PS_BOOTSTRAP_INSTALL_DIR}"
  printf '%s\n' "启动命令路径： ${PS_BOOTSTRAP_LAUNCHER_PATH}"
  printf '%s\n' "仓库元数据文件： ${meta_file}"
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

ps_repair_launcher() {
  ps_ui_info "正在修复/更新启动命令..."
  ps_ensure_local_launcher
  ps_ui_success "启动命令修复完成。"
}

main() {
  ps_prepare_runtime_dirs
  ps_logger_init

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
    ps_ui_menu_select_with_hint "主菜单" "推荐流程：创建服务 -> 创建本地入口 -> 创建转发链/路由 -> 导出并诊断。" "退出" "请选择" \
      "创建与管理服务" \
      "本地代理与转发" \
      "上游代理与出口" \
      "路由与规则" \
      "证书与域名" \
      "订阅与导出" \
      "运行状态与诊断" \
      "核心与运行控制" \
      "备份、清理与卸载" \
      "高级绑定/编排" \
      "高级设置"

    case "${PS_UI_LAST_CHOICE}" in
      1) ps_menu_service_management ;;
      2) ps_menu_local_proxy_forward ;;
      3) ps_menu_upstream_outbound ;;
      4) ps_menu_route_rules ;;
      5) ps_menu_cert_domain ;;
      6) ps_menu_subscribe_export ;;
      7) ps_menu_logs_diagnostics ;;
      8) ps_menu_engines_services ;;
      9) ps_menu_backup_restore ;;
      10) ps_menu_forwarding ;;
      11) ps_menu_advanced_settings ;;
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
