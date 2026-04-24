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
  if ps_command_exists xray; then
    local x_out
    x_out="$(xray x25519 2>/dev/null || true)"
    if [[ -n "${x_out}" ]]; then
      printf "%s\n" "${x_out}" | awk '
        /Private key:/ {priv=$3}
        /Public key:/ {pub=$3}
        END {
          if (priv != "" && pub != "") {
            printf "{\"private_key\":\"%s\",\"public_key\":\"%s\"}", priv, pub
          }
        }
      '
      return 0
    fi
  fi

  # TODO: Replace with strict X25519 derivation when xray helper is unavailable.
  jq -n \
    --arg priv "$(openssl rand -base64 32 | tr -d '\n=')" \
    --arg pub "$(openssl rand -base64 32 | tr -d '\n=')" \
    '{private_key:$priv, public_key:$pub}'
}

ps_pick_random_port() {
  local start="${1:-20000}"
  local end="${2:-60999}"
  ps_generate_safe_random_port "${start}" "${end}" || {
    ps_log_error "Unable to allocate a safe random port"
    return 1
  }
}
