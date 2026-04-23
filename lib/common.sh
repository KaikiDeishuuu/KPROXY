#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_COMMON_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_COMMON_SH_LOADED=1

PS_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PS_LIB_DIR="${PS_ROOT_DIR}/lib"
PS_TEMPLATES_DIR="${PS_ROOT_DIR}/templates"
PS_STATE_DIR="${PS_ROOT_DIR}/state"
PS_OUTPUT_DIR="${PS_ROOT_DIR}/output"
PS_BACKUP_DIR="${PS_ROOT_DIR}/backups"
PS_MANIFEST="${PS_STATE_DIR}/manifest.json"

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  PS_ETC_DIR="/etc/proxy-stack"
  PS_LOG_DIR="/var/log/proxy-stack"
  PS_SYSTEMD_DIR="/etc/systemd/system"
else
  PS_ETC_DIR="${PS_ROOT_DIR}/.runtime/etc"
  PS_LOG_DIR="${PS_ROOT_DIR}/.runtime/log"
  PS_SYSTEMD_DIR="${PS_ROOT_DIR}/.runtime/systemd"
fi

PS_CERT_DIR="${PS_ETC_DIR}/certs"
PS_XRAY_CONFIG="${PS_ETC_DIR}/xray.json"
PS_SINGBOX_CONFIG="${PS_ETC_DIR}/singbox.json"
PS_XRAY_SERVICE="proxy-stack-xray"
PS_SINGBOX_SERVICE="proxy-stack-singbox"
PS_INSTALL_LOG="${PS_LOG_DIR}/install.log"
PS_DEBUG="${PS_DEBUG:-0}"

ps_now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

ps_now_compact() {
  date +"%Y%m%d-%H%M%S"
}

ps_is_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

ps_print_header() {
  local title="${1:-}" 
  printf "\n========================================\n"
  printf "%s\n" "${title}"
  printf "========================================\n"
}

ps_pause() {
  read -r -p "Press Enter to continue..." _
}

ps_prompt() {
  local message="${1:-Input}" 
  local default_value="${2:-}" 
  local value

  if [[ -n "${default_value}" ]]; then
    read -r -p "${message} [${default_value}]: " value
    value="${value:-${default_value}}"
  else
    read -r -p "${message}: " value
  fi

  printf "%s" "${value}"
}

ps_prompt_required() {
  local message="${1:-Input required}" 
  local value
  while true; do
    read -r -p "${message}: " value
    if [[ -n "${value}" ]]; then
      printf "%s" "${value}"
      return 0
    fi
    printf "Value cannot be empty.\n" >&2
  done
}

ps_confirm() {
  local message="${1:-Are you sure?}" 
  local default_choice="${2:-N}"
  local answer

  if [[ "${default_choice}" == "Y" ]]; then
    read -r -p "${message} [Y/n]: " answer
    answer="${answer:-Y}"
  else
    read -r -p "${message} [y/N]: " answer
    answer="${answer:-N}"
  fi

  [[ "${answer}" =~ ^[Yy]$ ]]
}

ps_command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ps_require_cmds() {
  local cmd
  local missing=0
  for cmd in "$@"; do
    if ! ps_command_exists "${cmd}"; then
      printf "Missing dependency: %s\n" "${cmd}" >&2
      missing=1
    fi
  done
  return "${missing}"
}

ps_require_jq() {
  if ps_command_exists jq; then
    return 0
  fi

  printf "ERROR: Required dependency missing: jq\n" >&2
  printf "jq is required for manifest state operations and all jq-dependent runtime actions.\n" >&2
  printf "Debian/Ubuntu remediation: sudo apt-get update && sudo apt-get install -y jq\n" >&2
  return 2
}

ps_prepare_runtime_dirs() {
  mkdir -p "${PS_STATE_DIR}" "${PS_OUTPUT_DIR}" "${PS_BACKUP_DIR}" "${PS_ETC_DIR}" "${PS_LOG_DIR}" "${PS_CERT_DIR}" "${PS_SYSTEMD_DIR}"
}

ps_init_manifest() {
  ps_require_jq || return $?
  ps_prepare_runtime_dirs

  if [[ ! -f "${PS_MANIFEST}" ]]; then
    cat >"${PS_MANIFEST}" <<'JSON'
{
  "meta": {
    "project": "proxy-stack",
    "version": "0.1.0",
    "schema_version": 1,
    "created_at": "",
    "updated_at": ""
  },
  "engines": {
    "xray": {
      "installed": false,
      "version": "",
      "binary": "xray",
      "service": "proxy-stack-xray",
      "config_path": "/etc/proxy-stack/xray.json"
    },
    "singbox": {
      "installed": false,
      "version": "",
      "binary": "sing-box",
      "service": "proxy-stack-singbox",
      "config_path": "/etc/proxy-stack/singbox.json"
    }
  },
  "stacks": [],
  "inbounds": [],
  "outbounds": [
    {
      "tag": "direct",
      "type": "direct",
      "enabled": true
    },
    {
      "tag": "block",
      "type": "block",
      "enabled": true
    },
    {
      "tag": "dns-out",
      "type": "dns",
      "enabled": true
    }
  ],
  "routes": [
    {
      "name": "default-direct",
      "priority": 1000,
      "enabled": true,
      "inbound_tag": [],
      "domain_suffix": [],
      "domain_keyword": [],
      "ip_cidr": [],
      "network": [],
      "outbound": "direct"
    }
  ],
  "forwardings": [],
  "certificates": {},
  "logs": {
    "install_log": "/var/log/proxy-stack/install.log",
    "xray_access": "/var/log/proxy-stack/xray-access.log",
    "xray_error": "/var/log/proxy-stack/xray-error.log",
    "singbox_log": "/var/log/proxy-stack/singbox.log",
    "level": "warning",
    "dns_log": false,
    "mask_address": "quarter"
  },
  "exports": {
    "output_dir": "./output",
    "last_generated_at": "",
    "items": []
  }
}
JSON
  fi

  if ! jq . "${PS_MANIFEST}" >/dev/null 2>&1; then
    printf "Manifest is invalid JSON: %s\n" "${PS_MANIFEST}" >&2
    return 1
  fi

  local created_at
  created_at="$(jq -r '.meta.created_at // ""' "${PS_MANIFEST}")"
  if [[ -z "${created_at}" ]]; then
    ps_manifest_update --arg ts "$(ps_now_iso)" '.meta.created_at = $ts'
  fi
  ps_manifest_update '.forwardings = (.forwardings // [])'
  ps_manifest_update --arg ts "$(ps_now_iso)" '.meta.updated_at = $ts'
}

ps_manifest_query() {
  ps_require_jq || return $?
  local filter="${1:-.}"
  jq "${filter}" "${PS_MANIFEST}"
}

ps_manifest_update() {
  ps_require_jq || return $?
  local tmp
  tmp="$(mktemp)"
  if ! jq "$@" "${PS_MANIFEST}" >"${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  mv "${tmp}" "${PS_MANIFEST}"
}

ps_manifest_array_has() {
  ps_require_jq || return $?
  local array_filter="${1}" 
  local key="${2}" 
  local value="${3}"
  jq -e --arg v "${value}" "${array_filter} | any(.${key} == \$v)" "${PS_MANIFEST}" >/dev/null 2>&1
}

ps_generate_id() {
  local prefix="${1:-id}"
  printf "%s-%s-%04x" "${prefix}" "$(date +%s)" "$((RANDOM % 65536))"
}

ps_validate_port() {
  local port="${1:-0}"
  [[ "${port}" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535))
}

ps_port_is_well_known() {
  local port="${1:-0}"
  ps_validate_port "${port}" || return 1
  ((port <= 1024))
}

ps_port_is_listening() {
  local port="${1:-0}"
  ps_validate_port "${port}" || return 1

  if ps_command_exists ss; then
    ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(^|[:\]])${port}$"
    return $?
  fi

  if ps_command_exists netstat; then
    netstat -lntu 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[:\]])${port}$"
    return $?
  fi

  return 1
}

ps_port_is_recorded_in_manifest() {
  local port="${1:-0}"
  ps_validate_port "${port}" || return 1
  ps_require_jq || return $?

  jq -e --argjson p "${port}" '
    [
      (.stacks[]?.port // empty),
      (.inbounds[]?.port // empty),
      (.outbounds[]?.port // empty),
      (.forwardings[]?.listen_port // empty),
      (.forwardings[]?.target_port // empty)
    ]
    | map(select(type == "number"))
    | index($p) != null
  ' "${PS_MANIFEST}" >/dev/null 2>&1
}

ps_port_is_in_use() {
  local port="${1:-0}"
  ps_validate_port "${port}" || return 0

  if ps_port_is_listening "${port}"; then
    return 0
  fi

  if [[ -f "${PS_MANIFEST}" ]] && ps_port_is_recorded_in_manifest "${port}"; then
    return 0
  fi

  return 1
}

ps_generate_safe_random_port() {
  local start="${1:-20000}"
  local end="${2:-60999}"
  local tries=0

  while ((tries < 400)); do
    local port=$((RANDOM % (end - start + 1) + start))

    if ps_port_is_well_known "${port}"; then
      tries=$((tries + 1))
      continue
    fi

    if ps_port_is_in_use "${port}"; then
      tries=$((tries + 1))
      continue
    fi

    printf "%s" "${port}"
    return 0
  done

  return 1
}

ps_prompt_for_port() {
  local message="${1:-Port}"
  local start="${2:-20000}"
  local end="${3:-60999}"
  local input

  while true; do
    read -r -p "${message} [Enter=random available port]: " input

    if [[ -z "${input}" ]]; then
      local assigned
      assigned="$(ps_generate_safe_random_port "${start}" "${end}")" || {
        printf "Unable to find a safe random port.\n" >&2
        return 1
      }
      printf "Assigned random available port: %s\n" "${assigned}" >&2
      printf "%s" "${assigned}"
      return 0
    fi

    if ! ps_validate_port "${input}"; then
      printf "Invalid port: %s\n" "${input}" >&2
      continue
    fi

    if ps_port_is_in_use "${input}"; then
      printf "Port %s is occupied or already recorded in manifest. Choose another.\n" "${input}" >&2
      continue
    fi

    printf "%s" "${input}"
    return 0
  done
}

ps_backup_file_if_exists() {
  local file_path="${1}"
  local tag="${2:-file}"
  if [[ -f "${file_path}" ]]; then
    mkdir -p "${PS_BACKUP_DIR}"
    local backup_path="${PS_BACKUP_DIR}/${tag}-$(ps_now_compact).bak"
    cp -a "${file_path}" "${backup_path}"
    printf "%s" "${backup_path}"
  fi
}

ps_atomic_replace_file() {
  local source_file="${1}"
  local target_file="${2}"

  mkdir -p "$(dirname "${target_file}")"
  mv "${source_file}" "${target_file}"
}

ps_csv_to_json_array() {
  local csv="${1:-}"
  if [[ -z "${csv}" ]]; then
    printf '[]'
    return 0
  fi
  printf "%s" "${csv}" | awk -F',' '
    BEGIN { printf "[" }
    {
      for (i = 1; i <= NF; i++) {
        gsub(/^ +| +$/, "", $i)
        if ($i != "") {
          if (printed) { printf "," }
          gsub(/"/, "\\\"", $i)
          printf "\"%s\"", $i
          printed = 1
        }
      }
    }
    END { printf "]" }
  '
}
