#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_SINGBOX_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_SINGBOX_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"

ps_singbox_version_string() {
  local singbox_bin
  singbox_bin="$(ps_engine_binary singbox)"
  if [[ ! -x "${singbox_bin}" ]]; then
    if ps_command_exists sing-box; then
      singbox_bin="$(command -v sing-box)"
    else
      printf ""
      return 0
    fi
  fi

  if [[ ! -x "${singbox_bin}" ]]; then
    printf ""
    return 0
  fi
  "${singbox_bin}" version 2>/dev/null | head -n 1 | awk '{print $3}'
}

ps_singbox_update_manifest_status() {
  local installed="false"
  local version=""
  if [[ -x "$(ps_engine_binary singbox)" ]]; then
    installed="true"
    version="$(ps_singbox_version_string)"
  fi

  ps_manifest_update \
    --argjson installed "${installed}" \
    --arg version "${version}" \
    --arg binary "$(ps_engine_binary singbox)" \
    --arg config "$(ps_engine_config_path singbox)" \
    --arg service "$(ps_engine_service_name singbox)" \
    --arg ts "$(ps_now_iso)" \
    '.engines.singbox.installed = $installed | .engines.singbox.version = $version | .engines.singbox.binary = $binary | .engines.singbox.config_path = $config | .engines.singbox.service = $service | .meta.updated_at = $ts'
}

ps_singbox_install_upgrade() {
  ps_print_header "安装/升级 sing-box（kprxy 私有二进制）"
  if ! ps_require_cmds curl mktemp tar jq; then
    ps_log_error "缺少必需依赖（curl/mktemp/tar/jq）"
    return 1
  fi

  local arch_suffix
  case "${PS_ARCH}" in
    x86_64|amd64) arch_suffix="amd64" ;;
    aarch64|arm64) arch_suffix="arm64" ;;
    *)
      ps_log_warn "未识别架构 ${PS_ARCH}，默认尝试 amd64 包。"
      arch_suffix="amd64"
      ;;
  esac

  local api asset_url
  api="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest || true)"
  asset_url="$(jq -r --arg arch "${arch_suffix}" '.assets[]?.browser_download_url | select(test("linux-" + $arch + ".*\\.tar\\.gz$"))' <<<"${api}" | head -n 1)"

  local target_bin
  target_bin="$(ps_engine_binary singbox)"
  mkdir -p "$(dirname "${target_bin}")"

  if [[ -n "${asset_url}" ]]; then
    local tmpdir archive
    tmpdir="$(mktemp -d)"
    archive="${tmpdir}/sing-box.tar.gz"
    if curl -fsSL "${asset_url}" -o "${archive}"; then
      tar -xzf "${archive}" -C "${tmpdir}"
      local extracted
      extracted="$(find "${tmpdir}" -type f -name sing-box | head -n 1)"
      if [[ -n "${extracted}" && -f "${extracted}" ]]; then
        cp -f "${extracted}" "${target_bin}"
        chmod +x "${target_bin}"
        rm -rf "${tmpdir}"
        ps_singbox_update_manifest_status
        ps_log_success "sing-box 私有二进制已安装：${target_bin}"
        return 0
      fi
    fi
    rm -rf "${tmpdir}"
  fi

  if ps_command_exists sing-box; then
    cp -f "$(command -v sing-box)" "${target_bin}"
    chmod +x "${target_bin}"
    ps_singbox_update_manifest_status
    ps_log_warn "在线下载失败，已显式复用系统 sing-box 并复制到私有目录：${target_bin}"
    return 0
  fi

  ps_log_error "sing-box 安装失败：无法下载且系统中不存在 sing-box。"
  return 1
}

ps_singbox_validate_config() {
  local config_path="${1:-$(ps_engine_config_path singbox)}"
  local singbox_bin
  singbox_bin="$(ps_engine_binary singbox)"
  if [[ ! -x "${singbox_bin}" ]]; then
    ps_log_warn "sing-box 未安装，跳过校验"
    return 0
  fi

  if "${singbox_bin}" check -c "${config_path}" >/dev/null 2>&1; then
    ps_log_success "sing-box 配置校验通过"
    return 0
  fi

  ps_log_error "sing-box 配置校验失败： ${config_path}"
  return 1
}

ps_singbox_start() {
  systemctl start "${PS_SINGBOX_SERVICE}"
}

ps_singbox_stop() {
  systemctl stop "${PS_SINGBOX_SERVICE}"
}

ps_singbox_restart() {
  systemctl restart "${PS_SINGBOX_SERVICE}"
}

ps_singbox_reload() {
  systemctl reload "${PS_SINGBOX_SERVICE}"
}

ps_singbox_show_version() {
  ps_print_header "sing-box 版本"
  local singbox_bin
  singbox_bin="$(ps_engine_binary singbox)"
  if [[ ! -x "${singbox_bin}" ]]; then
    ps_log_warn "sing-box 未安装"
    return 1
  fi
  "${singbox_bin}" version
}

ps_singbox_uninstall() {
  ps_print_header "移除 sing-box（仅 kprxy 私有资源）"
  if ! ps_confirm "移除 kprxy 私有 sing-box 二进制吗？" "N"; then
    ps_log_info "已取消"
    return 0
  fi

  local target_bin
  target_bin="$(ps_engine_binary singbox)"
  if [[ -f "${target_bin}" ]]; then
    rm -f "${target_bin}"
    ps_log_info "已删除私有二进制：${target_bin}"
  else
    ps_log_warn "未找到私有二进制：${target_bin}"
  fi

  ps_singbox_update_manifest_status
  ps_log_success "sing-box 私有资源已移除（未修改系统全局安装）"
}
