#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_XRAY_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_XRAY_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"

ps_xray_version_string() {
  local xray_bin
  xray_bin="$(ps_engine_binary xray)"
  if [[ ! -x "${xray_bin}" ]]; then
    if ps_command_exists xray; then
      xray_bin="$(command -v xray)"
    else
      printf ""
      return 0
    fi
  fi

  if [[ ! -x "${xray_bin}" ]]; then
    printf ""
    return 0
  fi
  "${xray_bin}" version 2>/dev/null | head -n 1 | awk '{print $2}'
}

ps_xray_update_manifest_status() {
  local installed="false"
  local version=""
  if [[ -x "$(ps_engine_binary xray)" ]]; then
    installed="true"
    version="$(ps_xray_version_string)"
  fi

  ps_manifest_update \
    --argjson installed "${installed}" \
    --arg version "${version}" \
    --arg binary "$(ps_engine_binary xray)" \
    --arg config "$(ps_engine_config_path xray)" \
    --arg service "$(ps_engine_service_name xray)" \
    --arg ts "$(ps_now_iso)" \
    '.engines.xray.installed = $installed | .engines.xray.version = $version | .engines.xray.binary = $binary | .engines.xray.config_path = $config | .engines.xray.service = $service | .meta.updated_at = $ts'
}

ps_xray_install_upgrade() {
  ps_print_header "安装/升级 xray-core（kprxy 私有二进制）"

  if ! ps_require_cmds curl mktemp; then
    ps_log_error "缺少必需依赖"
    return 1
  fi

  local arch package_name
  case "${PS_ARCH}" in
    x86_64|amd64) package_name="Xray-linux-64.zip" ;;
    aarch64|arm64) package_name="Xray-linux-arm64-v8a.zip" ;;
    *)
      ps_log_warn "未识别架构 ${PS_ARCH}，默认尝试 amd64 包。"
      package_name="Xray-linux-64.zip"
      ;;
  esac

  local target_bin
  target_bin="$(ps_engine_binary xray)"

  local tmpdir archive_path extracted_bin
  tmpdir="$(mktemp -d)"
  archive_path="${tmpdir}/xray.zip"
  extracted_bin="${tmpdir}/xray"

  if curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/${package_name}" -o "${archive_path}" \
    && (unzip -j -o "${archive_path}" xray -d "${tmpdir}" >/dev/null 2>&1 || bsdtar -xOf "${archive_path}" xray >"${extracted_bin}" 2>/dev/null); then
    mkdir -p "$(dirname "${target_bin}")"
    chmod +x "${extracted_bin}" 2>/dev/null || true
    cp -f "${extracted_bin}" "${target_bin}"
    chmod +x "${target_bin}"
    ps_log_success "xray 私有二进制已安装：${target_bin}"
  elif ps_command_exists xray; then
    mkdir -p "$(dirname "${target_bin}")"
    cp -f "$(command -v xray)" "${target_bin}"
    chmod +x "${target_bin}"
    ps_log_warn "在线下载失败，已显式复用系统 xray 并复制到私有目录：${target_bin}"
  else
    rm -rf "${tmpdir}"
    ps_log_error "xray 安装失败：无法下载且系统中不存在 xray。"
    return 1
  fi
  rm -rf "${tmpdir}"

  ps_xray_update_manifest_status
  ps_log_success "xray-core 已安装/升级（隔离模式）"
}

ps_xray_validate_config() {
  local config_path="${1:-$(ps_engine_config_path xray)}"
  local xray_bin
  xray_bin="$(ps_engine_binary xray)"
  if [[ ! -x "${xray_bin}" ]]; then
    ps_log_warn "xray 未安装，跳过校验"
    return 0
  fi

  if "${xray_bin}" run -test -c "${config_path}" >/dev/null 2>&1; then
    ps_log_success "xray 配置校验通过"
    return 0
  fi

  ps_log_error "xray 配置校验失败： ${config_path}"
  return 1
}

ps_xray_start() {
  systemctl start "${PS_XRAY_SERVICE}"
}

ps_xray_stop() {
  systemctl stop "${PS_XRAY_SERVICE}"
}

ps_xray_restart() {
  systemctl restart "${PS_XRAY_SERVICE}"
}

ps_xray_reload() {
  systemctl reload "${PS_XRAY_SERVICE}"
}

ps_xray_show_version() {
  ps_print_header "xray-core 版本"
  local xray_bin
  xray_bin="$(ps_engine_binary xray)"
  if [[ ! -x "${xray_bin}" ]]; then
    ps_log_warn "xray 未安装"
    return 1
  fi
  "${xray_bin}" version
}

ps_xray_uninstall() {
  ps_print_header "移除 xray-core（仅 kprxy 私有资源）"
  if ! ps_confirm "移除 kprxy 私有 xray 二进制吗？" "N"; then
    ps_log_info "已取消"
    return 0
  fi

  local target_bin
  target_bin="$(ps_engine_binary xray)"
  if [[ -f "${target_bin}" ]]; then
    rm -f "${target_bin}"
    ps_log_info "已删除私有二进制：${target_bin}"
  else
    ps_log_warn "未找到私有二进制：${target_bin}"
  fi

  ps_xray_update_manifest_status
  ps_log_success "xray-core 私有资源已移除（未修改系统全局安装）"
}
