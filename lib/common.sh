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
PS_PROJECT_NAME="kprxy"

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  PS_HOME_DIR="/opt/kprxy"
  PS_RUNTIME_DIR="${PS_HOME_DIR}/runtime"
  PS_ETC_DIR="${PS_RUNTIME_DIR}"
  PS_LOG_DIR="${PS_RUNTIME_DIR}/log"
  PS_SYSTEMD_DIR="/etc/systemd/system"
else
  PS_HOME_DIR="${PS_ROOT_DIR}/.runtime/kprxy"
  PS_RUNTIME_DIR="${PS_HOME_DIR}/runtime"
  PS_ETC_DIR="${PS_RUNTIME_DIR}"
  PS_LOG_DIR="${PS_RUNTIME_DIR}/log"
  PS_SYSTEMD_DIR="${PS_ROOT_DIR}/.runtime/systemd"
fi

PS_BIN_DIR="${PS_HOME_DIR}/bin"
PS_ARCH="$(uname -m 2>/dev/null || printf "amd64")"
PS_XRAY_ARCH_SUFFIX="amd64"
case "${PS_ARCH}" in
  x86_64|amd64) PS_XRAY_ARCH_SUFFIX="amd64" ;;
  aarch64|arm64) PS_XRAY_ARCH_SUFFIX="arm64" ;;
esac
PS_CERT_DIR="${PS_HOME_DIR}/certs"
PS_XRAY_CONFIG="${PS_RUNTIME_DIR}/xray/config.json"
PS_SINGBOX_CONFIG="${PS_RUNTIME_DIR}/sing-box/config.json"
PS_XRAY_SERVICE="kprxy-xray"
PS_SINGBOX_SERVICE="kprxy-singbox"
PS_XRAY_BIN="${PS_BIN_DIR}/xray-linux-${PS_XRAY_ARCH_SUFFIX}"
PS_SINGBOX_BIN="${PS_BIN_DIR}/sing-box"
PS_INSTALL_LOG="${PS_LOG_DIR}/install.log"
PS_DEBUG="${PS_DEBUG:-0}"
PS_LOG_TERMINAL_ONLY="${PS_LOG_TERMINAL_ONLY:-0}"
PS_SESSION_TERMINATE_AFTER_ACTION="${PS_SESSION_TERMINATE_AFTER_ACTION:-0}"
PS_SESSION_TERMINATE_REASON="${PS_SESSION_TERMINATE_REASON:-}"

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
  read -r -p "按回车键继续..." _
}

ps_prompt() {
  local message="${1:-输入}" 
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
  local message="${1:-请输入内容}" 
  local value
  while true; do
    read -r -p "${message}: " value
    if [[ -n "${value}" ]]; then
      printf "%s" "${value}"
      return 0
    fi
    printf "输入不能为空。\n" >&2
  done
}

ps_confirm() {
  local message="${1:-确认执行吗？}" 
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

ps_strip_ansi() {
  local input="${1:-}"
  printf '%s' "${input}" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g'
}

ps_request_session_termination() {
  local reason="${1:-}"
  PS_SESSION_TERMINATE_AFTER_ACTION="1"
  PS_SESSION_TERMINATE_REASON="${reason}"
}

ps_command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ps_require_cmds() {
  local cmd
  local missing=0
  for cmd in "$@"; do
    if ! ps_command_exists "${cmd}"; then
      printf "缺少依赖： %s\n" "${cmd}" >&2
      missing=1
    fi
  done
  return "${missing}"
}

ps_require_jq() {
  if ps_command_exists jq; then
    return 0
  fi

  printf "错误：缺少必需依赖 jq\n" >&2
  printf "manifest 状态操作与所有依赖 jq 的运行时功能都需要 jq。\n" >&2
  printf "Debian/Ubuntu 安装命令： sudo apt-get update && sudo apt-get install -y jq\n" >&2
  return 2
}

ps_prepare_runtime_dirs() {
  mkdir -p "${PS_STATE_DIR}" "${PS_OUTPUT_DIR}" "${PS_BACKUP_DIR}" "${PS_ETC_DIR}" "${PS_LOG_DIR}" "${PS_CERT_DIR}" "${PS_SYSTEMD_DIR}" "${PS_BIN_DIR}" "$(dirname "${PS_XRAY_CONFIG}")" "$(dirname "${PS_SINGBOX_CONFIG}")"
}

ps_init_manifest() {
  ps_require_jq || return $?
  ps_prepare_runtime_dirs

  if [[ ! -f "${PS_MANIFEST}" ]]; then
    cat >"${PS_MANIFEST}" <<'JSON'
{
  "meta": {
    "project": "kprxy",
    "version": "0.1.0",
    "schema_version": 2,
    "public_address": "",
    "created_at": "",
    "updated_at": ""
  },
  "engines": {
    "xray": {
      "installed": false,
      "version": "",
      "binary": "/opt/kprxy/bin/xray-linux-amd64",
      "service": "kprxy-xray",
      "config_path": "/opt/kprxy/runtime/xray/config.json"
    },
    "singbox": {
      "installed": false,
      "version": "",
      "binary": "/opt/kprxy/bin/sing-box",
      "service": "kprxy-singbox",
      "config_path": "/opt/kprxy/runtime/sing-box/config.json"
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
    "install_log": "/opt/kprxy/runtime/log/install.log",
    "xray_access": "/opt/kprxy/runtime/log/xray-access.log",
    "xray_error": "/opt/kprxy/runtime/log/xray-error.log",
    "singbox_log": "/opt/kprxy/runtime/log/singbox.log",
    "level": "warning",
    "dns_log": false,
    "mask_address": "quarter"
  },
  "exports": {
    "output_dir": "./output",
    "last_generated_at": "",
    "items": []
  },
  "status": {
    "render": {
      "xray": {
        "ok": false,
        "message": "",
        "checked_at": ""
      },
      "singbox": {
        "ok": false,
        "message": "",
        "checked_at": ""
      }
    }
  }
}
JSON
  fi

  if ! jq . "${PS_MANIFEST}" >/dev/null 2>&1; then
    printf "manifest JSON 无效： %s\n" "${PS_MANIFEST}" >&2
    return 1
  fi

  local created_at
  created_at="$(jq -r '.meta.created_at // ""' "${PS_MANIFEST}")"
  if [[ -z "${created_at}" ]]; then
    ps_manifest_update --arg ts "$(ps_now_iso)" '.meta.created_at = $ts'
  fi
  ps_manifest_update '.meta.public_address = (.meta.public_address // "")'
  ps_manifest_update '.meta.schema_version = 2'
  ps_manifest_update '.forwardings = (.forwardings // [])'
  ps_manifest_update '.inbounds = (.inbounds // []) | .outbounds = (.outbounds // []) | .routes = (.routes // [])'
  ps_manifest_update '
    .inbounds |= map(
      .enabled = (.enabled // true)
      | .public = (.public // false)
      | .stack_id = (.stack_id // "")
    )
    | .outbounds |= map(.enabled = (.enabled // true))
    | .routes |= map(
        .enabled = (.enabled // true)
        | .inbound_tag = (.inbound_tag // [])
        | .domain_suffix = (.domain_suffix // [])
        | .domain_keyword = (.domain_keyword // [])
        | .ip_cidr = (.ip_cidr // [])
        | .network = (.network // [])
      )
    | .forwardings |= map(
        .enabled = (.enabled // true)
        | .route_name = (.route_name // "")
        | .inbound_tag = (.inbound_tag // "")
        | .outbound_tag = (.outbound_tag // "direct")
      )
  '
  ps_manifest_update '
    .status = (.status // {})
    | .status.render = (.status.render // {})
    | .status.render.xray = (.status.render.xray // {ok:false,message:"",checked_at:""})
    | .status.render.singbox = (.status.render.singbox // {ok:false,message:"",checked_at:""})
    | .status.render.xray.last_success_at = (.status.render.xray.last_success_at // (if (.status.render.xray.ok // false) == true then (.status.render.xray.checked_at // "") else "" end))
    | .status.render.singbox.last_success_at = (.status.render.singbox.last_success_at // (if (.status.render.singbox.ok // false) == true then (.status.render.singbox.checked_at // "") else "" end))
    | .status.render.xray.last_success_message = (.status.render.xray.last_success_message // (if (.status.render.xray.ok // false) == true then (.status.render.xray.message // "") else "" end))
    | .status.render.singbox.last_success_message = (.status.render.singbox.last_success_message // (if (.status.render.singbox.ok // false) == true then (.status.render.singbox.message // "") else "" end))
    | .status.render.xray.last_failure_at = (.status.render.xray.last_failure_at // (if (.status.render.xray.ok // false) == false then (.status.render.xray.checked_at // "") else "" end))
    | .status.render.singbox.last_failure_at = (.status.render.singbox.last_failure_at // (if (.status.render.singbox.ok // false) == false then (.status.render.singbox.checked_at // "") else "" end))
    | .status.render.xray.last_failure_message = (.status.render.xray.last_failure_message // (if (.status.render.xray.ok // false) == false then (.status.render.xray.message // "") else "" end))
    | .status.render.singbox.last_failure_message = (.status.render.singbox.last_failure_message // (if (.status.render.singbox.ok // false) == false then (.status.render.singbox.message // "") else "" end))
  '
  ps_manifest_update --arg install "${PS_LOG_DIR}/install.log" --arg xa "${PS_LOG_DIR}/xray-access.log" --arg xe "${PS_LOG_DIR}/xray-error.log" --arg sb "${PS_LOG_DIR}/singbox.log" '.logs.install_log = $install | .logs.xray_access = $xa | .logs.xray_error = $xe | .logs.singbox_log = $sb'
  ps_manifest_update --arg xbin "${PS_XRAY_BIN}" --arg sbin "${PS_SINGBOX_BIN}" --arg xcfg "${PS_XRAY_CONFIG}" --arg scfg "${PS_SINGBOX_CONFIG}" --arg xsvc "${PS_XRAY_SERVICE}" --arg ssvc "${PS_SINGBOX_SERVICE}" '.engines.xray.binary = $xbin | .engines.xray.config_path = $xcfg | .engines.xray.service = $xsvc | .engines.singbox.binary = $sbin | .engines.singbox.config_path = $scfg | .engines.singbox.service = $ssvc'
  ps_manifest_update --arg ts "$(ps_now_iso)" '.meta.updated_at = $ts'
}

ps_manifest_engine_field() {
  ps_require_jq || return $?
  local engine="${1}"
  local field="${2}"
  jq -r --arg e "${engine}" --arg f "${field}" '.engines[$e][$f] // empty' "${PS_MANIFEST}" 2>/dev/null
}

ps_engine_binary() {
  local engine="${1}"
  local fallback=""
  case "${engine}" in
    xray) fallback="${PS_XRAY_BIN}" ;;
    singbox) fallback="${PS_SINGBOX_BIN}" ;;
    *) printf ""; return 1 ;;
  esac

  if [[ -f "${PS_MANIFEST}" ]]; then
    local v
    v="$(ps_manifest_engine_field "${engine}" "binary" || true)"
    if [[ -n "${v}" ]]; then
      printf "%s" "${v}"
      return 0
    fi
  fi
  printf "%s" "${fallback}"
}

ps_engine_config_path() {
  local engine="${1}"
  local fallback=""
  case "${engine}" in
    xray) fallback="${PS_XRAY_CONFIG}" ;;
    singbox) fallback="${PS_SINGBOX_CONFIG}" ;;
    *) printf ""; return 1 ;;
  esac

  if [[ -f "${PS_MANIFEST}" ]]; then
    local v
    v="$(ps_manifest_engine_field "${engine}" "config_path" || true)"
    if [[ -n "${v}" ]]; then
      printf "%s" "${v}"
      return 0
    fi
  fi
  printf "%s" "${fallback}"
}

ps_engine_service_name() {
  local engine="${1}"
  local fallback=""
  case "${engine}" in
    xray) fallback="${PS_XRAY_SERVICE}" ;;
    singbox) fallback="${PS_SINGBOX_SERVICE}" ;;
    *) printf ""; return 1 ;;
  esac

  if [[ -f "${PS_MANIFEST}" ]]; then
    local v
    v="$(ps_manifest_engine_field "${engine}" "service" || true)"
    if [[ -n "${v}" ]]; then
      printf "%s" "${v}"
      return 0
    fi
  fi
  printf "%s" "${fallback}"
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
  mv -f "${tmp}" "${PS_MANIFEST}"
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
    ss -H -lntu 2>/dev/null | awk -v p="${port}" '$5 ~ ("(^|[:\\]])" p "$") { found=1; exit } END { exit(found ? 0 : 1) }'
    return $?
  fi

  if ps_command_exists netstat; then
    netstat -lntu 2>/dev/null | awk -v p="${port}" '$4 ~ ("(^|[:\\]])" p "$") { found=1; exit } END { exit(found ? 0 : 1) }'
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
      (.forwardings[]?.listen_port // empty)
    ]
    | map(select(type == "number"))
    | index($p) != null
  ' "${PS_MANIFEST}" >/dev/null 2>&1
}

ps_port_listener_owner() {
  local port="${1:-0}"
  ps_validate_port "${port}" || return 1
  if ! ps_command_exists ss; then
    return 1
  fi
  local line proc pid
  line="$(ss -H -lntup 2>/dev/null | awk -v p="${port}" '$5 ~ ("(^|[:\\]])" p "$") { print; exit }')"
  [[ -n "${line}" ]] || return 1

  proc="$(printf '%s\n' "${line}" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p')"
  pid="$(printf '%s\n' "${line}" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p')"
  printf '%s|%s\n' "${proc:--}" "${pid:--}"
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
    read -r -p "${message} [直接回车=随机可用端口]: " input

    if [[ -z "${input}" ]]; then
      local assigned
      assigned="$(ps_generate_safe_random_port "${start}" "${end}")" || {
        printf "无法找到安全的随机端口。\n" >&2
        return 1
      }
      printf "已分配随机可用端口： %s\n" "${assigned}" >&2
      printf "%s" "${assigned}"
      return 0
    fi

    if ! ps_validate_port "${input}"; then
      printf "端口无效： %s\n" "${input}" >&2
      continue
    fi

    if ps_port_is_in_use "${input}"; then
      local owner
      owner="$(ps_port_listener_owner "${input}" || true)"
      if [[ -n "${owner}" ]]; then
        IFS='|' read -r proc pid <<<"${owner}"
        if [[ "${proc}" =~ ^(xray|sing-box|x-ui|3x-ui)$ ]]; then
          printf "端口 %s 冲突：已被 %s（PID=%s）占用，请更换或显式复用。\n" "${input}" "${proc}" "${pid:-未知}" >&2
          continue
        fi
        printf "端口 %s 已被占用（进程=%s，PID=%s），请更换。\n" "${input}" "${proc:-未知}" "${pid:-未知}" >&2
      else
        printf "端口 %s 已被占用或已记录在 manifest 中，请更换。\n" "${input}" >&2
      fi
      continue
    fi

    printf "%s" "${input}"
    return 0
  done
}

ps_detect_public_ipv4() {
  local services=(
    "https://api.ipify.org"
    "https://ipv4.icanhazip.com"
    "https://ifconfig.me/ip"
  )
  local svc ip
  for svc in "${services[@]}"; do
    ip="$(curl -4fsS --max-time 3 "${svc}" 2>/dev/null | tr -d '\r\n' || true)"
    if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s' "${ip}"
      return 0
    fi
  done
  return 1
}

ps_prompt_public_address() {
  local message="${1:-节点对外地址（用于订阅与分享，直接回车使用自动检测值）}"
  local saved=""

  if [[ -f "${PS_MANIFEST}" ]]; then
    saved="$(jq -r '.meta.public_address // ""' "${PS_MANIFEST}" 2>/dev/null || true)"
  fi
  if [[ -n "${saved}" ]]; then
    ps_log_info "已复用已保存节点地址：${saved}" >&2
    printf '%s' "${saved}"
    return 0
  fi

  local detected=""
  local value=""
  detected="$(ps_detect_public_ipv4 || true)"
  if [[ -n "${detected}" ]]; then
    ps_log_info "已自动检测公网 IPv4：${detected}" >&2
    value="$(ps_prompt "${message}" "${detected}")"
  else
    ps_log_warn "自动检测公网 IPv4 失败，请手动输入可被客户端访问的公网域名或 IP。" >&2
    value="$(ps_prompt_required "${message}")"
  fi

  if [[ -n "${value}" && -f "${PS_MANIFEST}" ]]; then
    ps_manifest_update --arg addr "${value}" --arg ts "$(ps_now_iso)" '.meta.public_address = $addr | .meta.updated_at = $ts' || true
  fi

  printf '%s' "${value}"
}

ps_remember_public_address() {
  local addr="${1:-}"
  [[ -n "${addr}" ]] || return 0
  [[ -f "${PS_MANIFEST}" ]] || return 0

  ps_manifest_update --arg addr "${addr}" --arg ts "$(ps_now_iso)" '.meta.public_address = $addr | .meta.updated_at = $ts'
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
