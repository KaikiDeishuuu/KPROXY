#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_INBOUND_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_INBOUND_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"

ps_inbound_pick_tag() {
  mapfile -t rows < <(jq -r '.inbounds[] | "\(.tag)|\(.type)|\(.listen):\(.port)|\(.enabled)"' "${PS_MANIFEST}")
  if [[ "${#rows[@]}" -eq 0 ]]; then
    ps_log_warn "No inbound found."
    return 1
  fi

  local i=1 row
  printf "\n"
  for row in "${rows[@]}"; do
    IFS='|' read -r tag type endpoint enabled <<<"${row}"
    printf "%d) %s type=%s endpoint=%s enabled=%s\n" "${i}" "${tag}" "${type}" "${endpoint}" "${enabled}"
    i=$((i + 1))
  done

  local choice
  choice="$(ps_prompt_required "Select inbound number")"
  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#rows[@]})); then
    ps_log_error "Invalid inbound selection"
    return 1
  fi

  IFS='|' read -r tag _ <<<"${rows[choice-1]}"
  printf "%s" "${tag}"
}

ps_inbound_list() {
  ps_print_header "Inbound List"
  jq -r '
    if (.inbounds | length) == 0 then
      "No inbounds configured."
    else
      (.inbounds[] |
        "- \(.tag) type=\(.type) listen=\(.listen):\(.port) udp=\(.udp) stack=\(.stack_id // "-") enabled=\(.enabled)")
    end
  ' "${PS_MANIFEST}"
}

ps_inbound_create_public() {
  ps_print_header "Create Public Server Inbound"
  local stack_id

  mapfile -t stacks < <(jq -r '.stacks[] | "\(.stack_id)|\(.name)|\(.protocol)|\(.port)"' "${PS_MANIFEST}")
  if [[ "${#stacks[@]}" -eq 0 ]]; then
    ps_log_warn "No stack found. Please create stack first."
    return 1
  fi

  local i=1 row
  for row in "${stacks[@]}"; do
    IFS='|' read -r sid name protocol port <<<"${row}"
    printf "%d) %s (%s:%s) [%s]\n" "${i}" "${name}" "${protocol}" "${port}" "${sid}"
    i=$((i + 1))
  done

  local selected
  selected="$(ps_prompt_required "Select stack number")"
  if ! [[ "${selected}" =~ ^[0-9]+$ ]] || ((selected < 1 || selected > ${#stacks[@]})); then
    ps_log_error "Invalid selection"
    return 1
  fi

  IFS='|' read -r stack_id _ protocol stack_port <<<"${stacks[selected-1]}"
  local tag listen port
  tag="$(ps_prompt "Inbound tag" "pub-${stack_id}")"
  listen="$(ps_prompt "Listen address" "0.0.0.0")"
  port="$(ps_prompt_for_port "Listen port (recommended ${stack_port}, Enter=random)")"

  if ! ps_validate_port "${port}"; then
    ps_log_error "Invalid port"
    return 1
  fi

  if ps_manifest_array_has '.inbounds' 'tag' "${tag}"; then
    ps_log_error "Inbound tag already exists: ${tag}"
    return 1
  fi

  local inbound_json
  inbound_json="$(jq -n \
    --arg tag "${tag}" \
    --arg type "${protocol}" \
    --arg listen "${listen}" \
    --argjson port "${port}" \
    --arg stack_id "${stack_id}" \
    --arg created_at "$(ps_now_iso)" \
    '{tag:$tag,type:$type,listen:$listen,port:$port,auth:{},udp:true,stack_id:$stack_id,public:true,enabled:true,created_at:$created_at,updated_at:$created_at}')"

  ps_manifest_update --argjson inbound "${inbound_json}" --arg ts "$(ps_now_iso)" '.inbounds += [$inbound] | .meta.updated_at = $ts'
  ps_log_success "Public inbound created: ${tag}"
}

ps_inbound_create_local() {
  ps_print_header "Create Local Inbound"
  printf "1) SOCKS5\n2) HTTP\n3) Mixed\n"
  local type_choice inbound_type
  type_choice="$(ps_prompt_required "Inbound type number")"
  case "${type_choice}" in
    1) inbound_type="socks" ;;
    2) inbound_type="http" ;;
    3) inbound_type="mixed" ;;
    *) ps_log_error "Invalid type"; return 1 ;;
  esac

  local default_port="1080"
  [[ "${inbound_type}" == "http" ]] && default_port="8080"

  local tag listen port username password udp
  tag="$(ps_prompt "Inbound tag" "local-${inbound_type}-$(ps_generate_id in | awk -F'-' '{print $NF}')")"
  listen="$(ps_prompt "Listen address" "127.0.0.1")"
  port="$(ps_prompt_for_port "Listen port (suggested ${default_port}, Enter=random)")"
  username="$(ps_prompt "Auth username (optional)" "")"
  password="$(ps_prompt "Auth password (optional)" "")"
  udp="$(ps_prompt "Enable UDP (true/false)" "true")"

  if ! ps_validate_port "${port}"; then
    ps_log_error "Invalid port"
    return 1
  fi

  if ps_manifest_array_has '.inbounds' 'tag' "${tag}"; then
    ps_log_error "Inbound tag already exists: ${tag}"
    return 1
  fi

  local inbound_json
  inbound_json="$(jq -n \
    --arg tag "${tag}" \
    --arg type "${inbound_type}" \
    --arg listen "${listen}" \
    --argjson port "${port}" \
    --arg username "${username}" \
    --arg password "${password}" \
    --argjson udp "${udp}" \
    --arg created_at "$(ps_now_iso)" \
    '{tag:$tag,type:$type,listen:$listen,port:$port,auth:{username:$username,password:$password},udp:$udp,stack_id:"",public:false,enabled:true,created_at:$created_at,updated_at:$created_at}')"

  ps_manifest_update --argjson inbound "${inbound_json}" --arg ts "$(ps_now_iso)" '.inbounds += [$inbound] | .meta.updated_at = $ts'
  ps_log_success "Local inbound created: ${tag}"
}

ps_inbound_edit() {
  ps_print_header "Edit Inbound"
  local tag
  tag="$(ps_inbound_pick_tag)" || return 1

  local listen port udp username password
  listen="$(ps_prompt "New listen address (empty to keep)" "")"
  port="$(ps_prompt "New port (empty to keep)" "")"
  udp="$(ps_prompt "UDP true/false (empty to keep)" "")"
  username="$(ps_prompt "Auth username (empty to keep)" "")"
  password="$(ps_prompt "Auth password (empty to keep)" "")"

  if [[ -n "${port}" ]] && ! ps_validate_port "${port}"; then
    ps_log_error "Invalid port"
    return 1
  fi

  local jq_filter='.inbounds |= map(if .tag == $tag then . else . end)'

  if [[ -n "${listen}" ]]; then
    jq_filter+=' | .inbounds |= map(if .tag == $tag then .listen = $listen else . end)'
  fi
  if [[ -n "${port}" ]]; then
    jq_filter+=' | .inbounds |= map(if .tag == $tag then .port = ($port|tonumber) else . end)'
  fi
  if [[ -n "${udp}" ]]; then
    jq_filter+=' | .inbounds |= map(if .tag == $tag then .udp = ($udp == "true") else . end)'
  fi
  if [[ -n "${username}" ]]; then
    jq_filter+=' | .inbounds |= map(if .tag == $tag then .auth.username = $username else . end)'
  fi
  if [[ -n "${password}" ]]; then
    jq_filter+=' | .inbounds |= map(if .tag == $tag then .auth.password = $password else . end)'
  fi

  jq_filter+=' | .inbounds |= map(if .tag == $tag then .updated_at = $ts else . end) | .meta.updated_at = $ts'

  ps_manifest_update \
    --arg tag "${tag}" \
    --arg listen "${listen}" \
    --arg port "${port}" \
    --arg udp "${udp}" \
    --arg username "${username}" \
    --arg password "${password}" \
    --arg ts "$(ps_now_iso)" \
    "${jq_filter}"

  ps_log_success "Inbound updated: ${tag}"
}

ps_inbound_delete() {
  ps_print_header "Delete Inbound"
  local tag
  tag="$(ps_inbound_pick_tag)" || return 1

  if ! ps_confirm "Delete inbound ${tag}?" "N"; then
    ps_log_info "Cancelled"
    return 0
  fi

  ps_manifest_update --arg tag "${tag}" --arg ts "$(ps_now_iso)" '.inbounds |= map(select(.tag != $tag)) | .meta.updated_at = $ts'
  ps_log_success "Inbound deleted: ${tag}"
}

ps_inbound_bind_stack() {
  ps_print_header "Bind Inbound to Stack"
  local tag stack_id
  tag="$(ps_inbound_pick_tag)" || return 1

  mapfile -t stacks < <(jq -r '.stacks[] | "\(.stack_id)|\(.name)|\(.engine)"' "${PS_MANIFEST}")
  if [[ "${#stacks[@]}" -eq 0 ]]; then
    ps_log_warn "No stacks available"
    return 1
  fi

  local i=1 row
  for row in "${stacks[@]}"; do
    IFS='|' read -r sid name engine <<<"${row}"
    printf "%d) %s [%s] (%s)\n" "${i}" "${name}" "${sid}" "${engine}"
    i=$((i + 1))
  done

  local choice
  choice="$(ps_prompt_required "Select stack number")"
  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#stacks[@]})); then
    ps_log_error "Invalid selection"
    return 1
  fi

  IFS='|' read -r stack_id _ <<<"${stacks[choice-1]}"

  ps_manifest_update --arg tag "${tag}" --arg stack_id "${stack_id}" --arg ts "$(ps_now_iso)" '.inbounds |= map(if .tag == $tag then .stack_id = $stack_id | .updated_at = $ts else . end) | .meta.updated_at = $ts'
  ps_log_success "Inbound ${tag} bound to stack ${stack_id}"
}
