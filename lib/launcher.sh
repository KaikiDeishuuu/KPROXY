#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_LAUNCHER_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_LAUNCHER_SH_LOADED=1

ps_launcher_log_info() {
  if declare -F ps_log_info >/dev/null 2>&1; then
    ps_log_info "$*"
  else
    printf "[启动器] %s\n" "$*"
  fi
}

ps_launcher_log_warn() {
  if declare -F ps_log_warn >/dev/null 2>&1; then
    ps_log_warn "$*"
  else
    printf "[启动器] 警告： %s\n" "$*" >&2
  fi
}

ps_launcher_log_error() {
  if declare -F ps_log_error >/dev/null 2>&1; then
    ps_log_error "$*"
  else
    printf "[启动器] 错误： %s\n" "$*" >&2
  fi
}

ps_launcher_path_has_dir() {
  local dir="${1}"
  local path_value=":${PATH:-}:"
  [[ "${path_value}" == *":${dir}:"* ]]
}

ps_launcher_can_write_dir() {
  local dir="${1}"
  local parent

  if [[ -d "${dir}" ]]; then
    [[ -w "${dir}" ]]
    return $?
  fi

  parent="$(dirname "${dir}")"
  [[ -d "${parent}" ]] || mkdir -p "${parent}" 2>/dev/null || return 1
  [[ -w "${parent}" ]]
}

ps_launcher_resolve_install_dir() {
  local explicit_install_dir="${1:-}"

  if [[ -n "${explicit_install_dir}" ]]; then
    printf "%s" "${explicit_install_dir}"
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    if ps_launcher_can_write_dir "/opt"; then
      printf "%s" "/opt/kprxy"
      return 0
    fi
    printf "%s" "/usr/local/share/kprxy"
    return 0
  fi

  printf "%s" "${HOME}/.local/share/kprxy"
}

ps_launcher_resolve_launcher_path() {
  local explicit_launcher_path="${1:-}"

  if [[ -n "${explicit_launcher_path}" ]]; then
    printf "%s" "${explicit_launcher_path}"
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -eq 0 && -w "/usr/local/bin" ]]; then
    printf "%s" "/usr/local/bin/kprxy"
    return 0
  fi

  printf "%s" "${HOME}/.local/bin/kprxy"
}

ps_launcher_install() {
  local project_dir="${1}"
  local launcher_path="${2}"
  local entry_script="${3:-install.sh}"

  if [[ -e "${launcher_path}" && ! -f "${launcher_path}" ]]; then
    ps_launcher_log_error "Launcher path exists and is not a regular file: ${launcher_path}"
    return 1
  fi

  mkdir -p "$(dirname "${launcher_path}")"

  local tmp
  tmp="$(mktemp "${launcher_path}.tmp.XXXXXX")"
  cat >"${tmp}" <<EOF_LAUNCHER
#!/usr/bin/env bash
set -euo pipefail
exec bash "${project_dir}/${entry_script}" "\$@"
EOF_LAUNCHER

  chmod 0755 "${tmp}"
  mv -f "${tmp}" "${launcher_path}"
  ps_launcher_log_info "Launcher installed/updated: ${launcher_path}"
}

ps_launcher_verify() {
  local launcher_path="${1}"
  [[ -x "${launcher_path}" ]]
}

ps_launcher_print_path_hint() {
  local launcher_path="${1}"
  local launcher_dir
  launcher_dir="$(dirname "${launcher_path}")"

  if ps_launcher_path_has_dir "${launcher_dir}"; then
    ps_launcher_log_info "启动器目录已在 PATH 中：${launcher_dir}"
    return 0
  fi

  ps_launcher_log_warn "启动器目录不在 PATH 中：${launcher_dir}"
  printf "\n请加入 shell 配置后重新打开终端：\n"
  printf "  export PATH=\"%s:\$PATH\"\n" "${launcher_dir}"
  printf "\nbash 可执行：\n"
  printf "  echo 'export PATH=\"%s:\$PATH\"' >> ~/.bashrc\n" "${launcher_dir}"
  printf "zsh 可执行：\n"
  printf "  echo 'export PATH=\"%s:\$PATH\"' >> ~/.zshrc\n\n" "${launcher_dir}"
}

ps_launcher_record_hint_marker() {
  local marker_file="${1:-}"
  [[ -n "${marker_file}" ]] || return 0
  mkdir -p "$(dirname "${marker_file}")"
  printf "shown_at=%s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "${marker_file}"
}

ps_launcher_maybe_print_path_hint() {
  local launcher_path="${1}"
  local marker_file="${2:-}"
  local mode="${3:-install}"
  local launcher_dir
  launcher_dir="$(dirname "${launcher_path}")"

  if ps_launcher_path_has_dir "${launcher_dir}"; then
    return 0
  fi

  if [[ -n "${marker_file}" && -f "${marker_file}" ]]; then
    return 0
  fi

  if [[ "${mode}" == "runtime" ]]; then
    ps_launcher_log_warn "当前 PATH 无法解析 kprxy，请将 ${launcher_dir} 加入 PATH。"
    ps_launcher_record_hint_marker "${marker_file}"
    return 0
  fi

  ps_launcher_print_path_hint "${launcher_path}"
  ps_launcher_record_hint_marker "${marker_file}"
}

ps_launcher_print_success() {
  local project_dir="${1}"
  local launcher_path="${2}"

  printf "\n安装完成。\n\n"
  printf "项目路径： %s\n" "${project_dir}"
  printf "启动器： %s\n\n" "${launcher_path}"
  printf "可随时运行：\n"
  printf "  kprxy\n\n"
}
