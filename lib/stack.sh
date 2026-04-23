#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_STACK_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_STACK_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"
# shellcheck source=lib/crypto.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/crypto.sh"

ps_stack_preset_layers() {
  local preset="${1}"
  case "${preset}" in
    "VLESS-Vision-TLS")
      jq -n '{protocol:"vless", security:"tls", transport:"tcp", vision:true, utls:false, flow:"xtls-rprx-vision"}'
      ;;
    "VLESS-Vision-uTLS-REALITY")
      jq -n '{protocol:"vless", security:"reality", transport:"tcp", vision:true, utls:true, flow:"xtls-rprx-vision"}'
      ;;
    "VLESS-gRPC-uTLS-REALITY")
      jq -n '{protocol:"vless", security:"reality", transport:"grpc", vision:false, utls:true, flow:""}'
      ;;
    "VLESS-Reality-XHTTP")
      jq -n '{protocol:"vless", security:"reality", transport:"xhttp", vision:false, utls:true, flow:""}'
      ;;
    "Shadowsocks 2022")
      jq -n '{protocol:"shadowsocks-2022", security:"none", transport:"tcp", vision:false, utls:false, flow:""}'
      ;;
    "Shadowsocks 2022-TLS")
      jq -n '{protocol:"shadowsocks-2022", security:"tls", transport:"tcp", vision:false, utls:false, flow:""}'
      ;;
    *)
      jq -n '{protocol:"vless", security:"tls", transport:"tcp", vision:false, utls:false, flow:""}'
      ;;
  esac
}

ps_stack_pick_id() {
  mapfile -t rows < <(jq -r '.stacks[] | "\(.stack_id)|\(.name)|\(.engine)|\(.enabled)"' "${PS_MANIFEST}")
  if [[ "${#rows[@]}" -eq 0 ]]; then
    ps_log_warn "No stacks found."
    return 1
  fi

  local i=1
  local row
  printf "\n"
  for row in "${rows[@]}"; do
    IFS='|' read -r stack_id name engine enabled <<<"${row}"
    printf "%d) %s [%s] enabled=%s\n" "${i}" "${name}" "${engine}" "${enabled}"
    i=$((i + 1))
  done

  local selected
  selected="$(ps_prompt_required "Select stack number")"
  if ! [[ "${selected}" =~ ^[0-9]+$ ]] || ((selected < 1 || selected > ${#rows[@]})); then
    ps_log_error "Invalid selection."
    return 1
  fi

  IFS='|' read -r stack_id _ <<<"${rows[selected-1]}"
  printf "%s" "${stack_id}"
}

ps_stack_list() {
  ps_print_header "Installed Stacks"
  jq -r '
    if (.stacks | length) == 0 then
      "No stacks installed."
    else
      (.stacks[] |
        "- [\(.stack_id)] \(.name) engine=\(.engine) protocol=\(.protocol) security=\(.security) transport=\(.transport) port=\(.port) enabled=\(.enabled)")
    end
  ' "${PS_MANIFEST}"
}

ps_stack_create() {
  ps_print_header "Create New Stack"
  local preset_choice
  local preset_name
  printf "1) VLESS-Vision-TLS\n"
  printf "2) VLESS-Vision-uTLS-REALITY\n"
  printf "3) VLESS-gRPC-uTLS-REALITY\n"
  printf "4) VLESS-Reality-XHTTP\n"
  printf "5) Shadowsocks 2022\n"
  printf "6) Shadowsocks 2022-TLS\n"
  printf "7) Custom template\n"

  preset_choice="$(ps_prompt_required "Preset number")"
  case "${preset_choice}" in
    1) preset_name="VLESS-Vision-TLS" ;;
    2) preset_name="VLESS-Vision-uTLS-REALITY" ;;
    3) preset_name="VLESS-gRPC-uTLS-REALITY" ;;
    4) preset_name="VLESS-Reality-XHTTP" ;;
    5) preset_name="Shadowsocks 2022" ;;
    6) preset_name="Shadowsocks 2022-TLS" ;;
    7) preset_name="Custom template" ;;
    *)
      ps_log_error "Invalid preset."
      return 1
      ;;
  esac

  local engine
  printf "1) xray\n2) singbox\n"
  case "$(ps_prompt_required "Engine number")" in
    1) engine="xray" ;;
    2) engine="singbox" ;;
    *) ps_log_error "Invalid engine."; return 1 ;;
  esac

  local layer_json
  if [[ "${preset_name}" == "Custom template" ]]; then
    local protocol security transport vision utls flow
    protocol="$(ps_prompt "Protocol (vless/shadowsocks-2022)" "vless")"

    if [[ "${protocol}" == "shadowsocks-2022" ]]; then
      security="$(ps_prompt "Security (none/tls)" "none")"
      transport="tcp"
      vision="false"
      utls="false"
      flow=""
    else
      security="$(ps_prompt "Security (tls/reality/none)" "tls")"
      transport="$(ps_prompt "Transport (tcp/grpc/xhttp)" "tcp")"
      vision="$(ps_prompt "Vision flow (true/false)" "false")"
      utls="$(ps_prompt "uTLS enabled (true/false)" "false")"
      flow="$(ps_prompt "Flow" "")"
    fi

    layer_json="$(jq -n --arg protocol "${protocol}" --arg security "${security}" --arg transport "${transport}" --arg flow "${flow}" --argjson vision "${vision}" --argjson utls "${utls}" '{protocol:$protocol, security:$security, transport:$transport, vision:$vision, utls:$utls, flow:$flow}')"
  else
    layer_json="$(ps_stack_preset_layers "${preset_name}")"
  fi

  local stack_protocol stack_security
  stack_protocol="$(jq -r '.protocol' <<<"${layer_json}")"
  stack_security="$(jq -r '.security' <<<"${layer_json}")"

  if [[ "${stack_protocol}" == "shadowsocks-2022" && "${stack_security}" == "reality" ]]; then
    ps_log_error "Shadowsocks 2022 does not support REALITY in this scaffold. Use none/tls."
    return 1
  fi

  if [[ "${stack_protocol}" == "shadowsocks-2022" && "${stack_security}" != "none" && "${stack_security}" != "tls" ]]; then
    ps_log_error "Invalid SS2022 security: ${stack_security}. Use none/tls."
    return 1
  fi

  local name server port tls_cert_mode
  name="$(ps_prompt_required "Stack name")"
  server="$(ps_prompt_required "Server domain/IP")"
  port="$(ps_prompt_for_port "Server listen port (type a port or press Enter for random)")"
  if ! ps_validate_port "${port}"; then
    ps_log_error "Invalid port: ${port}"
    return 1
  fi
  if [[ "${stack_security}" == "tls" ]]; then
    tls_cert_mode="$(ps_prompt "TLS cert mode (acme/manual)" "acme")"
    if [[ "${stack_protocol}" == "shadowsocks-2022" && "${engine}" == "singbox" ]]; then
      ps_log_warn "SS2022+TLS for sing-box may vary by version; renderer will validate before applying."
    fi
  else
    tls_cert_mode="none"
  fi

  local client_sni="" client_fingerprint=""
  if [[ "${stack_protocol}" == "vless" ]]; then
    client_sni="$(ps_prompt "Client SNI (for share links/uTLS)" "${server}")"
    client_fingerprint="$(ps_prompt "Client fingerprint (chrome/firefox/safari/edge/randomized)" "chrome")"
  fi

  local stack_id uuid
  stack_id="$(ps_generate_id stack)"
  uuid="$(ps_generate_uuid)"

  local reality_json grpc_json xhttp_json ss_json
  reality_json='{"enabled":false,"server_name":"","dest":"","private_key":"","public_key":"","short_id":"","fingerprint":"chrome"}'
  grpc_json='{"service_name":"grpc","idle_timeout":"15s","health_check_timeout":"20s"}'
  xhttp_json='{"path":"/","host":"","mode":"auto"}'
  ss_json='{"method":"2022-blake3-aes-128-gcm","password":""}'

  if [[ "${stack_security}" == "reality" ]]; then
    local keypair
    keypair="$(ps_generate_reality_keypair)"
    reality_json="$(jq -n \
      --arg enabled true \
      --arg sni "${server}" \
      --arg dest "${server}:443" \
      --arg private_key "$(jq -r '.private_key' <<<"${keypair}")" \
      --arg public_key "$(jq -r '.public_key' <<<"${keypair}")" \
      --arg short_id "$(ps_generate_short_id)" \
      --arg fingerprint "chrome" \
      '{enabled:($enabled == "true"),server_name:$sni,dest:$dest,private_key:$private_key,public_key:$public_key,short_id:$short_id,fingerprint:$fingerprint}')"
  fi

  if [[ "${stack_protocol}" == "shadowsocks-2022" ]]; then
    ss_json="$(jq -n --arg method "2022-blake3-aes-128-gcm" --arg password "$(ps_generate_ss2022_password)" '{method:$method,password:$password}')"
  fi

  local stack_json
  stack_json="$(jq -n \
    --arg stack_id "${stack_id}" \
    --arg name "${name}" \
    --arg engine "${engine}" \
    --arg protocol "$(jq -r '.protocol' <<<"${layer_json}")" \
    --arg security "$(jq -r '.security' <<<"${layer_json}")" \
    --arg transport "$(jq -r '.transport' <<<"${layer_json}")" \
    --arg tls_cert_mode "${tls_cert_mode}" \
    --arg server "${server}" \
    --argjson port "${port}" \
    --arg uuid "${uuid}" \
    --arg sni "${client_sni}" \
    --arg fingerprint "${client_fingerprint}" \
    --arg flow "$(jq -r '.flow' <<<"${layer_json}")" \
    --argjson vision "$(jq -r '.vision' <<<"${layer_json}")" \
    --argjson utls "$(jq -r '.utls' <<<"${layer_json}")" \
    --arg preset "${preset_name}" \
    --argjson reality "${reality_json}" \
    --argjson grpc "${grpc_json}" \
    --argjson xhttp "${xhttp_json}" \
    --argjson ss2022 "${ss_json}" \
    --arg created_at "$(ps_now_iso)" \
    '{
      stack_id:$stack_id,
      name:$name,
      preset:$preset,
      engine:$engine,
      protocol:$protocol,
      security:$security,
      transport:$transport,
      vision:$vision,
      utls:$utls,
      tls_cert_mode:$tls_cert_mode,
      server:$server,
      port:$port,
      uuid:$uuid,
      sni:$sni,
      fingerprint:$fingerprint,
      flow:$flow,
      reality:$reality,
      grpc:$grpc,
      xhttp:$xhttp,
      ss2022:$ss2022,
      tls:{domain:$server,fullchain:"",key:""},
      enabled:true,
      created_at:$created_at,
      updated_at:$created_at
    }')"

  ps_manifest_update --argjson stack "${stack_json}" --arg ts "$(ps_now_iso)" '.stacks += [$stack] | .meta.updated_at = $ts'
  ps_log_success "Stack created: ${name} (${stack_id})"
}

ps_stack_edit() {
  ps_print_header "Edit Stack"
  local stack_id
  stack_id="$(ps_stack_pick_id)" || return 1

  local name server port engine cert_mode sni fingerprint
  name="$(ps_prompt "New name (leave empty to keep)" "")"
  server="$(ps_prompt "Server domain/IP (leave empty to keep)" "")"
  port="$(ps_prompt "Port (leave empty to keep)" "")"
  engine="$(ps_prompt "Engine (xray/singbox, empty to keep)" "")"
  cert_mode="$(ps_prompt "TLS cert mode (acme/manual/none, empty to keep)" "")"
  sni="$(ps_prompt "Client SNI (leave empty to keep)" "")"
  fingerprint="$(ps_prompt "Client fingerprint (leave empty to keep)" "")"

  local jq_filter='.stacks |= map(if .stack_id == $id then . else . end)'

  if [[ -n "${name}" ]]; then
    jq_filter+=' | .stacks |= map(if .stack_id == $id then .name = $name else . end)'
  fi
  if [[ -n "${server}" ]]; then
    jq_filter+=' | .stacks |= map(if .stack_id == $id then .server = $server | .tls.domain = $server else . end)'
  fi
  if [[ -n "${port}" ]]; then
    if ! ps_validate_port "${port}"; then
      ps_log_error "Invalid port"
      return 1
    fi
    jq_filter+=' | .stacks |= map(if .stack_id == $id then .port = ($port|tonumber) else . end)'
  fi
  if [[ -n "${engine}" ]]; then
    jq_filter+=' | .stacks |= map(if .stack_id == $id then .engine = $engine else . end)'
  fi
  if [[ -n "${cert_mode}" ]]; then
    jq_filter+=' | .stacks |= map(if .stack_id == $id then .tls_cert_mode = $cert_mode else . end)'
  fi
  if [[ -n "${sni}" ]]; then
    jq_filter+=' | .stacks |= map(if .stack_id == $id then .sni = $sni else . end)'
  fi
  if [[ -n "${fingerprint}" ]]; then
    jq_filter+=' | .stacks |= map(if .stack_id == $id then .fingerprint = $fingerprint else . end)'
  fi

  jq_filter+=' | .stacks |= map(if .stack_id == $id then .updated_at = $ts else . end) | .meta.updated_at = $ts'

  ps_manifest_update \
    --arg id "${stack_id}" \
    --arg name "${name}" \
    --arg server "${server}" \
    --arg port "${port}" \
    --arg engine "${engine}" \
    --arg cert_mode "${cert_mode}" \
    --arg sni "${sni}" \
    --arg fingerprint "${fingerprint}" \
    --arg ts "$(ps_now_iso)" \
    "${jq_filter}"
  ps_log_success "Stack updated: ${stack_id}"
}

ps_stack_delete() {
  ps_print_header "Delete Stack"
  local stack_id
  stack_id="$(ps_stack_pick_id)" || return 1
  if ! ps_confirm "Delete stack ${stack_id}?" "N"; then
    ps_log_info "Cancelled."
    return 0
  fi

  ps_manifest_update --arg id "${stack_id}" --arg ts "$(ps_now_iso)" '.stacks |= map(select(.stack_id != $id)) | .inbounds |= map(if .stack_id == $id then .stack_id = "" else . end) | .meta.updated_at = $ts'
  ps_log_success "Stack deleted: ${stack_id}"
}

ps_stack_toggle() {
  ps_print_header "Enable/Disable Stack"
  local stack_id
  stack_id="$(ps_stack_pick_id)" || return 1

  local current
  current="$(jq -r --arg id "${stack_id}" '.stacks[] | select(.stack_id == $id) | .enabled' "${PS_MANIFEST}")"
  local target="true"
  if [[ "${current}" == "true" ]]; then
    target="false"
  fi

  ps_manifest_update --arg id "${stack_id}" --argjson enabled "${target}" --arg ts "$(ps_now_iso)" '.stacks |= map(if .stack_id == $id then .enabled = $enabled | .updated_at = $ts else . end) | .meta.updated_at = $ts'
  ps_log_success "Stack ${stack_id} enabled=${target}"
}

ps_stack_rerender() {
  if declare -F ps_render_all >/dev/null 2>&1; then
    ps_render_all
  else
    ps_log_warn "Render module not loaded."
  fi
}
