#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_CRYPTO_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_CRYPTO_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"

ps_generate_uuid() {
  if ps_command_exists xray; then
    xray uuid
    return 0
  fi

  if ps_command_exists uuidgen; then
    uuidgen
    return 0
  fi

  if [[ -f /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
    return 0
  fi

  # Fallback keeps a UUID-like shape when no helper is available.
  local hex
  hex="$(openssl rand -hex 16)"
  printf "%s-%s-%s-%s-%s\n" "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
}

ps_generate_short_id() {
  openssl rand -hex 8
}

ps_is_valid_reality_key() {
  local key="${1:-}"
  [[ "${key}" =~ ^[A-Za-z0-9_-]{43}$ ]]
}

ps_is_valid_reality_short_id() {
  local short_id="${1:-}"
  [[ -z "${short_id}" || "${short_id}" =~ ^([0-9A-Fa-f]{2}){0,8}$ ]]
}

ps_extract_x25519_key_from_output() {
  local output="${1:-}"
  local field="${2:-private}"
  local key=""

  case "${field}" in
    private)
      key="$(printf '%s\n' "${output}" | sed -n 's/^[[:space:]]*Private key:[[:space:]]*//p' | head -n 1 | tr -d '\r')"
      ;;
    public)
      key="$(printf '%s\n' "${output}" | sed -n 's/^[[:space:]]*Public key:[[:space:]]*//p' | head -n 1 | tr -d '\r')"
      ;;
    *)
      return 1
      ;;
  esac

  printf '%s' "${key}"
}

ps_ss2022_key_length_for_method() {
  local method="${1:-2022-blake3-aes-128-gcm}"
  case "${method}" in
    2022-blake3-aes-128-gcm) printf "16" ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) printf "32" ;;
    *)
      # Unknown methods fall back to 32 bytes, which is broadly compatible.
      printf "32"
      ;;
  esac
}

ps_generate_ss2022_password() {
  local method="${1:-2022-blake3-aes-128-gcm}"
  local key_length
  key_length="$(ps_ss2022_key_length_for_method "${method}")"
  openssl rand -base64 "${key_length}" | tr -d '\n'
}

ps_generate_reality_keypair() {
  local xray_bin=""
  local x_out=""
  local private_key=""
  local public_key=""

  if [[ -x "$(ps_engine_binary xray 2>/dev/null || true)" ]]; then
    xray_bin="$(ps_engine_binary xray)"
  elif ps_command_exists xray; then
    xray_bin="$(command -v xray)"
  fi

  if [[ -z "${xray_bin}" ]]; then
    ps_log_error "无法生成 REALITY 密钥：未找到 xray x25519 生成器。"
    return 1
  fi

  x_out="$("${xray_bin}" x25519 2>/dev/null || true)"
  if [[ -z "${x_out}" ]]; then
    ps_log_error "无法生成 REALITY 密钥：xray x25519 执行失败。"
    return 1
  fi

  private_key="$(ps_extract_x25519_key_from_output "${x_out}" private)"
  public_key="$(ps_extract_x25519_key_from_output "${x_out}" public)"

  if ! ps_is_valid_reality_key "${private_key}"; then
    ps_log_error "无法生成 REALITY 密钥：private_key 格式无效。"
    return 1
  fi
  if ! ps_is_valid_reality_key "${public_key}"; then
    ps_log_error "无法生成 REALITY 密钥：public_key 格式无效。"
    return 1
  fi

  jq -n --arg priv "${private_key}" --arg pub "${public_key}" '{private_key:$priv, public_key:$pub}'
}

ps_pick_random_port() {
  local start="${1:-20000}"
  local end="${2:-60999}"
  ps_generate_safe_random_port "${start}" "${end}" || {
    ps_log_error "Unable to allocate a safe random port"
    return 1
  }
}
