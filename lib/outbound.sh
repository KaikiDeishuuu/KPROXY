#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_OUTBOUND_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_OUTBOUND_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"
# shellcheck source=lib/crypto.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/crypto.sh"

ps_outbound_pick_tag() {
  mapfile -t rows < <(jq -r '.outbounds[] | "\(.tag)|\(.type)|\(.enabled)"' "${PS_MANIFEST}")
  if [[ "${#rows[@]}" -eq 0 ]]; then
    ps_log_warn "No outbound found."
    return 1
  fi

  local i=1 row
  printf "\n"
  for row in "${rows[@]}"; do
    IFS='|' read -r tag type enabled <<<"${row}"
    printf "%d) %s type=%s enabled=%s\n" "${i}" "${tag}" "${type}" "${enabled}"
    i=$((i + 1))
  done

  local choice
  choice="$(ps_prompt_required "Select outbound number")"
  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#rows[@]})); then
    ps_log_error "Invalid outbound selection"
    return 1
  fi

  IFS='|' read -r tag _ <<<"${rows[choice-1]}"
  printf "%s" "${tag}"
}

ps_outbound_list() {
  ps_print_header "Outbound List"
  jq -r '
    if (.outbounds | length) == 0 then
      "No outbounds configured."
    else
      (.outbounds[] |
        "- \(.tag) type=\(.type) server=\(.server // "-"):\(.port // "-") enabled=\(.enabled)")
    end
  ' "${PS_MANIFEST}"
}

ps_outbound_create() {
  ps_print_header "Create Outbound"
  printf "1) direct\n"
  printf "2) block\n"
  printf "3) dns\n"
  printf "4) socks5 upstream\n"
  printf "5) http upstream\n"
  printf "6) vless remote\n"
  printf "7) shadowsocks remote\n"
  printf "8) selector (sing-box preferred)\n"

  local kind type
  kind="$(ps_prompt_required "Outbound type number")"
  case "${kind}" in
    1) type="direct" ;;
    2) type="block" ;;
    3) type="dns" ;;
    4) type="socks5" ;;
    5) type="http" ;;
    6) type="vless" ;;
    7) type="shadowsocks" ;;
    8) type="selector" ;;
    *) ps_log_error "Invalid outbound type"; return 1 ;;
  esac

  local default_tag="${type}-$(ps_generate_id out | awk -F'-' '{print $NF}')"
  local tag
  if [[ "${type}" == "direct" || "${type}" == "block" || "${type}" == "dns" ]]; then
    default_tag="${type}"
  fi
  tag="$(ps_prompt "Outbound tag" "${default_tag}")"

  if ps_manifest_array_has '.outbounds' 'tag' "${tag}"; then
    ps_log_error "Outbound tag already exists: ${tag}"
    return 1
  fi

  local server="" port="0" username="" password="" network="tcp" sni="" fingerprint="" uuid="" method="" members_json='[]'
  if [[ "${type}" =~ ^(socks5|http|vless|shadowsocks)$ ]]; then
    server="$(ps_prompt_required "Remote server")"
    port="$(ps_prompt_for_port "Remote port (type a port or press Enter for random)")"
    if ! ps_validate_port "${port}"; then
      ps_log_error "Invalid port"
      return 1
    fi
  fi

  case "${type}" in
    socks5|http)
      username="$(ps_prompt "Username (optional)" "")"
      password="$(ps_prompt "Password (optional)" "")"
      ;;
    vless)
      uuid="$(ps_prompt "UUID" "$(ps_generate_uuid)")"
      sni="$(ps_prompt "SNI" "${server}")"
      fingerprint="$(ps_prompt "Fingerprint (chrome/firefox/safari/edge/randomized)" "chrome")"
      network="$(ps_prompt "Network (tcp/grpc/ws)" "tcp")"
      ;;
    shadowsocks)
      method="$(ps_prompt "Method" "2022-blake3-aes-128-gcm")"
      password="$(ps_prompt "Password" "$(ps_generate_ss2022_password)")"
      ;;
    selector)
      members_json="$(ps_csv_to_json_array "$(ps_prompt "Members (comma separated outbound tags)" "direct,block")")"
      ;;
  esac

  local outbound_json
  outbound_json="$(jq -n \
    --arg tag "${tag}" \
    --arg type "${type}" \
    --arg server "${server}" \
    --argjson port "${port}" \
    --arg username "${username}" \
    --arg password "${password}" \
    --arg network "${network}" \
    --arg sni "${sni}" \
    --arg fingerprint "${fingerprint}" \
    --arg uuid "${uuid}" \
    --arg method "${method}" \
    --argjson members "${members_json}" \
    --arg created_at "$(ps_now_iso)" \
    '{
      tag:$tag,
      type:$type,
      server:$server,
      port:$port,
      auth:{username:$username,password:$password},
      network:$network,
      sni:$sni,
      fingerprint:$fingerprint,
      uuid:$uuid,
      method:$method,
      password:$password,
      members:$members,
      enabled:true,
      created_at:$created_at,
      updated_at:$created_at
    }')"

  ps_manifest_update --argjson outbound "${outbound_json}" --arg ts "$(ps_now_iso)" '.outbounds += [$outbound] | .meta.updated_at = $ts'
  ps_log_success "Outbound created: ${tag}"
}

ps_outbound_edit() {
  ps_print_header "Edit Outbound"
  local tag
  tag="$(ps_outbound_pick_tag)" || return 1

  local new_server new_port username password network sni fingerprint enabled
  new_server="$(ps_prompt "Server (empty to keep)" "")"
  new_port="$(ps_prompt "Port (empty to keep)" "")"
  username="$(ps_prompt "Username (empty to keep)" "")"
  password="$(ps_prompt "Password (empty to keep)" "")"
  network="$(ps_prompt "Network (empty to keep)" "")"
  sni="$(ps_prompt "SNI (empty to keep)" "")"
  fingerprint="$(ps_prompt "Fingerprint (empty to keep)" "")"
  enabled="$(ps_prompt "Enabled true/false (empty to keep)" "")"

  if [[ -n "${new_port}" ]] && ! ps_validate_port "${new_port}"; then
    ps_log_error "Invalid port"
    return 1
  fi

  local jq_filter='.outbounds |= map(if .tag == $tag then . else . end)'
  [[ -n "${new_server}" ]] && jq_filter+=' | .outbounds |= map(if .tag == $tag then .server = $server else . end)'
  [[ -n "${new_port}" ]] && jq_filter+=' | .outbounds |= map(if .tag == $tag then .port = ($port|tonumber) else . end)'
  [[ -n "${username}" ]] && jq_filter+=' | .outbounds |= map(if .tag == $tag then .auth.username = $username else . end)'
  [[ -n "${password}" ]] && jq_filter+=' | .outbounds |= map(if .tag == $tag then .auth.password = $password | .password = $password else . end)'
  [[ -n "${network}" ]] && jq_filter+=' | .outbounds |= map(if .tag == $tag then .network = $network else . end)'
  [[ -n "${sni}" ]] && jq_filter+=' | .outbounds |= map(if .tag == $tag then .sni = $sni else . end)'
  [[ -n "${fingerprint}" ]] && jq_filter+=' | .outbounds |= map(if .tag == $tag then .fingerprint = $fingerprint else . end)'
  [[ -n "${enabled}" ]] && jq_filter+=' | .outbounds |= map(if .tag == $tag then .enabled = ($enabled == "true") else . end)'

  jq_filter+=' | .outbounds |= map(if .tag == $tag then .updated_at = $ts else . end) | .meta.updated_at = $ts'

  ps_manifest_update \
    --arg tag "${tag}" \
    --arg server "${new_server}" \
    --arg port "${new_port}" \
    --arg username "${username}" \
    --arg password "${password}" \
    --arg network "${network}" \
    --arg sni "${sni}" \
    --arg fingerprint "${fingerprint}" \
    --arg enabled "${enabled}" \
    --arg ts "$(ps_now_iso)" \
    "${jq_filter}"

  ps_log_success "Outbound updated: ${tag}"
}

ps_outbound_delete() {
  ps_print_header "Delete Outbound"
  local tag
  tag="$(ps_outbound_pick_tag)" || return 1

  if [[ "${tag}" == "direct" || "${tag}" == "block" || "${tag}" == "dns-out" ]]; then
    ps_log_warn "Builtin outbound cannot be deleted: ${tag}"
    return 1
  fi

  if ! ps_confirm "Delete outbound ${tag}?" "N"; then
    ps_log_info "Cancelled"
    return 0
  fi

  ps_manifest_update --arg tag "${tag}" --arg ts "$(ps_now_iso)" '.outbounds |= map(select(.tag != $tag)) | .routes |= map(if .outbound == $tag then .outbound = "direct" else . end) | .meta.updated_at = $ts'
  ps_log_success "Outbound deleted: ${tag}"
}
