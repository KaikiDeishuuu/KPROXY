#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_SUBSCRIBE_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_SUBSCRIBE_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"

ps_sub_url_encode() {
  local value="${1:-}"
  printf "%s" "${value}" | sed \
    -e 's/%/%25/g' \
    -e 's/ /%20/g' \
    -e 's/;/%3B/g' \
    -e 's/=/%3D/g' \
    -e 's/:/%3A/g' \
    -e 's/?/%3F/g' \
    -e 's/&/%26/g' \
    -e 's/#/%23/g' \
    -e 's|/|%2F|g'
}

ps_sub_yaml_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf "%s" "${value}"
}

ps_sub_create_export_root() {
  local label="${1:-subscription-export}"
  mkdir -p "${PS_OUTPUT_DIR}"

  local root="${PS_OUTPUT_DIR}/${label}-$(ps_now_compact)"
  local suffix=1
  while [[ -e "${root}" ]]; do
    root="${PS_OUTPUT_DIR}/${label}-$(ps_now_compact)-${suffix}"
    suffix=$((suffix + 1))
  done

  mkdir -p "${root}"
  printf "%s" "${root}"
}

ps_sub_prepare_bundle_dirs() {
  local root="${1:-}"
  if [[ -z "${root}" ]]; then
    ps_log_error "Missing export root directory"
    return 1
  fi

  mkdir -p \
    "${root}/subscriptions" \
    "${root}/clash" \
    "${root}/clash/rules" \
    "${root}/xray" \
    "${root}/singbox" \
    "${root}/rules"
}

ps_sub_write_initialized_rules_bundle() {
  local root="${1:-}"
  if [[ -z "${root}" ]]; then
    ps_log_error "Missing export root for rules bundle"
    return 1
  fi

  ps_sub_prepare_bundle_dirs "${root}" || return 1

  local tpl_root="${PS_TEMPLATES_DIR}/rules"
  local files=(
    "custom_direct.yaml"
    "custom_proxy.yaml"
    "custom_reject.yaml"
    "lan.yaml"
    "default_rules.yaml"
    "README.md"
  )

  local file src dst
  for file in "${files[@]}"; do
    src="${tpl_root}/${file}.tpl"
    if [[ ! -f "${src}" ]]; then
      ps_log_error "Missing rules template: ${src}"
      return 1
    fi

    dst="${root}/rules/${file}"
    cp "${src}" "${dst}"
    cp "${src}" "${root}/clash/rules/${file}"
  done

  return 0
}

ps_sub_record_export() {
  local export_type="${1}"
  local export_path="${2}"
  local item_json
  item_json="$(jq -n --arg type "${export_type}" --arg path "${export_path}" --arg ts "$(ps_now_iso)" '{type:$type,path:$path,generated_at:$ts}')"
  ps_manifest_update --argjson item "${item_json}" --arg ts "$(ps_now_iso)" '.exports.items += [$item] | .exports.last_generated_at = $ts | .meta.updated_at = $ts'
}

ps_sub_stack_link_from_json() {
  local stack_json="${1}"
  local protocol
  protocol="$(jq -r '.protocol' <<<"${stack_json}")"

  if [[ "${protocol}" == "vless" ]]; then
    local uuid server port name security transport flow query sni fingerprint
    uuid="$(jq -r '.uuid' <<<"${stack_json}")"
    server="$(jq -r '.server' <<<"${stack_json}")"
    port="$(jq -r '.port' <<<"${stack_json}")"
    name="$(jq -r '.name' <<<"${stack_json}")"
    security="$(jq -r '.security // "none"' <<<"${stack_json}")"
    transport="$(jq -r '.transport // "tcp"' <<<"${stack_json}")"
    flow="$(jq -r '.flow // ""' <<<"${stack_json}")"
    sni="$(jq -r '.sni // .server' <<<"${stack_json}")"
    fingerprint="$(jq -r '.fingerprint // "chrome"' <<<"${stack_json}")"

    query="encryption=none"
    if [[ "${security}" == "tls" ]]; then
      query+="&security=tls"
      query+="&sni=$(ps_sub_url_encode "${sni}")"
      query+="&fp=$(ps_sub_url_encode "${fingerprint}")"
    elif [[ "${security}" == "reality" ]]; then
      query+="&security=reality"
      query+="&sni=$(ps_sub_url_encode "$(jq -r '.reality.server_name // .sni // .server' <<<"${stack_json}")")"
      query+="&fp=$(ps_sub_url_encode "$(jq -r '.reality.fingerprint // .fingerprint // "chrome"' <<<"${stack_json}")")"
      query+="&pbk=$(ps_sub_url_encode "$(jq -r '.reality.public_key // ""' <<<"${stack_json}")")"
      query+="&sid=$(ps_sub_url_encode "$(jq -r '.reality.short_id // ""' <<<"${stack_json}")")"
    fi

    case "${transport}" in
      grpc)
        query+="&type=grpc&serviceName=$(ps_sub_url_encode "$(jq -r '.grpc.service_name // "grpc"' <<<"${stack_json}")")"
        ;;
      xhttp)
        query+="&type=xhttp&path=$(ps_sub_url_encode "$(jq -r '.xhttp.path // "/"' <<<"${stack_json}")")"
        ;;
      *)
        query+="&type=tcp"
        ;;
    esac

    if [[ -n "${flow}" ]]; then
      query+="&flow=$(ps_sub_url_encode "${flow}")"
    fi

    printf "vless://%s@%s:%s?%s#%s\n" "${uuid}" "${server}" "${port}" "${query}" "$(ps_sub_url_encode "${name}")"
    return 0
  fi

  if [[ "${protocol}" == "shadowsocks-2022" ]]; then
    local method password server port name userinfo security plugin_query tls_host
    method="$(jq -r '.ss2022.method // "2022-blake3-aes-128-gcm"' <<<"${stack_json}")"
    password="$(jq -r '.ss2022.password // ""' <<<"${stack_json}")"
    server="$(jq -r '.server' <<<"${stack_json}")"
    port="$(jq -r '.port' <<<"${stack_json}")"
    name="$(jq -r '.name' <<<"${stack_json}")"
    security="$(jq -r '.security // "none"' <<<"${stack_json}")"
    userinfo="$(printf "%s:%s" "${method}" "${password}" | base64 -w 0)"

    plugin_query=""
    if [[ "${security}" == "tls" ]]; then
      tls_host="$(jq -r '.tls.domain // .server' <<<"${stack_json}")"
      plugin_query="/?plugin=$(ps_sub_url_encode "v2ray-plugin;tls;host=${tls_host}")"
    fi

    printf "ss://%s@%s:%s%s#%s\n" "${userinfo}" "${server}" "${port}" "${plugin_query}" "$(ps_sub_url_encode "${name}")"
    return 0
  fi

  return 1
}

ps_sub_collect_links() {
  jq -c '.stacks[]? | select(.enabled == true)' "${PS_MANIFEST}" | while IFS= read -r stack; do
    ps_sub_stack_link_from_json "${stack}" || true
  done
}

ps_sub_generate_share_links() {
  ps_print_header "Generate Share Links"

  local root="${1:-}"
  [[ -z "${root}" ]] && root="$(ps_sub_create_export_root "subscription")"
  ps_sub_prepare_bundle_dirs "${root}" || return 1
  ps_sub_write_initialized_rules_bundle "${root}" || return 1

  local out_file="${root}/subscriptions/all.txt"
  local links
  links="$(ps_sub_collect_links)"

  if [[ -z "${links}" ]]; then
    ps_log_warn "No enabled stacks for share links"
    return 1
  fi

  printf "%s\n" "${links}" >"${out_file}"
  ps_sub_record_export "share-links" "${out_file}"
  ps_log_success "Share links exported: ${out_file}"
  ps_log_info "Initialized rules prepared: ${root}/rules"
  printf "%s\n" "${links}"
}

ps_sub_generate_base64_subscription() {
  ps_print_header "Generate Base64 Subscription"

  local root="${1:-}"
  [[ -z "${root}" ]] && root="$(ps_sub_create_export_root "subscription")"
  ps_sub_prepare_bundle_dirs "${root}" || return 1
  ps_sub_write_initialized_rules_bundle "${root}" || return 1

  local links_file="${root}/subscriptions/all.txt"
  local links
  if [[ -f "${links_file}" ]]; then
    links="$(cat "${links_file}")"
  else
    links="$(ps_sub_collect_links)"
  fi

  if [[ -z "${links}" ]]; then
    ps_log_warn "No enabled stacks for subscription"
    return 1
  fi

  printf "%s\n" "${links}" >"${links_file}"

  local out_file="${root}/subscriptions/all.b64.txt"
  printf "%s" "${links}" | base64 -w 0 >"${out_file}"
  ps_sub_record_export "subscription-base64" "${out_file}"
  ps_log_success "Base64 subscription exported: ${out_file}"
  ps_log_info "Initialized rules prepared: ${root}/rules"
}

ps_sub_clash_proxy_from_stack() {
  local stack_json="${1}"
  local protocol
  protocol="$(jq -r '.protocol' <<<"${stack_json}")"

  local name server port
  name="$(jq -r '.name' <<<"${stack_json}")"
  server="$(jq -r '.server' <<<"${stack_json}")"
  port="$(jq -r '.port' <<<"${stack_json}")"

  if [[ "${protocol}" == "vless" ]]; then
    local security transport flow sni fingerprint
    security="$(jq -r '.security // "none"' <<<"${stack_json}")"
    transport="$(jq -r '.transport // "tcp"' <<<"${stack_json}")"
    flow="$(jq -r '.flow // ""' <<<"${stack_json}")"
    sni="$(jq -r '.sni // .server' <<<"${stack_json}")"
    fingerprint="$(jq -r '.fingerprint // "chrome"' <<<"${stack_json}")"

    printf "  - name: \"%s\"\n" "$(ps_sub_yaml_escape "${name}")"
    printf "    type: vless\n"
    printf "    server: \"%s\"\n" "$(ps_sub_yaml_escape "${server}")"
    printf "    port: %s\n" "${port}"
    printf "    uuid: \"%s\"\n" "$(ps_sub_yaml_escape "$(jq -r '.uuid' <<<"${stack_json}")")"
    printf "    udp: true\n"

    case "${transport}" in
      grpc)
        printf "    network: grpc\n"
        printf "    grpc-opts:\n"
        printf "      grpc-service-name: \"%s\"\n" "$(ps_sub_yaml_escape "$(jq -r '.grpc.service_name // "grpc"' <<<"${stack_json}")")"
        ;;
      xhttp)
        # Clash.Meta does not have a dedicated xhttp type, ws is used as a compatible fallback.
        printf "    network: ws\n"
        printf "    ws-opts:\n"
        printf "      path: \"%s\"\n" "$(ps_sub_yaml_escape "$(jq -r '.xhttp.path // "/"' <<<"${stack_json}")")"
        ;;
      *)
        printf "    network: tcp\n"
        ;;
    esac

    if [[ "${security}" == "tls" || "${security}" == "reality" ]]; then
      printf "    tls: true\n"
      if [[ "${security}" == "reality" ]]; then
        local reality_sni reality_fp reality_pbk reality_sid
        reality_sni="$(jq -r '.reality.server_name // .sni // .server' <<<"${stack_json}")"
        reality_fp="$(jq -r '.reality.fingerprint // .fingerprint // "chrome"' <<<"${stack_json}")"
        reality_pbk="$(jq -r '.reality.public_key // ""' <<<"${stack_json}")"
        reality_sid="$(jq -r '.reality.short_id // ""' <<<"${stack_json}")"

        printf "    servername: \"%s\"\n" "$(ps_sub_yaml_escape "${reality_sni}")"
        printf "    client-fingerprint: \"%s\"\n" "$(ps_sub_yaml_escape "${reality_fp}")"
        if [[ -n "${reality_pbk}" || -n "${reality_sid}" ]]; then
          printf "    reality-opts:\n"
          [[ -n "${reality_pbk}" ]] && printf "      public-key: \"%s\"\n" "$(ps_sub_yaml_escape "${reality_pbk}")"
          [[ -n "${reality_sid}" ]] && printf "      short-id: \"%s\"\n" "$(ps_sub_yaml_escape "${reality_sid}")"
        fi
      else
        printf "    servername: \"%s\"\n" "$(ps_sub_yaml_escape "${sni}")"
        printf "    client-fingerprint: \"%s\"\n" "$(ps_sub_yaml_escape "${fingerprint}")"
      fi
    else
      printf "    tls: false\n"
    fi

    if [[ -n "${flow}" ]]; then
      printf "    flow: \"%s\"\n" "$(ps_sub_yaml_escape "${flow}")"
    fi

    return 0
  fi

  if [[ "${protocol}" == "shadowsocks-2022" ]]; then
    local method password security tls_host
    method="$(jq -r '.ss2022.method // "2022-blake3-aes-128-gcm"' <<<"${stack_json}")"
    password="$(jq -r '.ss2022.password // ""' <<<"${stack_json}")"
    security="$(jq -r '.security // "none"' <<<"${stack_json}")"

    printf "  - name: \"%s\"\n" "$(ps_sub_yaml_escape "${name}")"
    printf "    type: ss\n"
    printf "    server: \"%s\"\n" "$(ps_sub_yaml_escape "${server}")"
    printf "    port: %s\n" "${port}"
    printf "    cipher: \"%s\"\n" "$(ps_sub_yaml_escape "${method}")"
    printf "    password: \"%s\"\n" "$(ps_sub_yaml_escape "${password}")"
    printf "    udp: true\n"

    if [[ "${security}" == "tls" ]]; then
      tls_host="$(jq -r '.tls.domain // .server' <<<"${stack_json}")"
      printf "    plugin: \"v2ray-plugin\"\n"
      printf "    plugin-opts:\n"
      printf "      mode: tls\n"
      printf "      host: \"%s\"\n" "$(ps_sub_yaml_escape "${tls_host}")"
    fi

    return 0
  fi

  return 1
}

ps_sub_export_initialized_rules_bundle() {
  ps_print_header "Export Initialized Rules Bundle"

  local root="${1:-}"
  [[ -z "${root}" ]] && root="$(ps_sub_create_export_root "rules")"

  ps_sub_write_initialized_rules_bundle "${root}" || return 1
  ps_sub_record_export "rules-bundle" "${root}/rules"
  ps_log_success "Initialized rules bundle exported: ${root}/rules"
  ps_log_info "Clash-compatible rules mirror: ${root}/clash/rules"
}

ps_sub_export_clash_meta() {
  ps_print_header "Export Clash.Meta Config"

  local root="${1:-}"
  [[ -z "${root}" ]] && root="$(ps_sub_create_export_root "clash")"
  ps_sub_prepare_bundle_dirs "${root}" || return 1
  ps_sub_write_initialized_rules_bundle "${root}" || return 1

  local template="${PS_TEMPLATES_DIR}/clash/meta.yaml.tpl"
  local out_file="${root}/clash/config.yaml"

  if [[ ! -f "${template}" ]]; then
    ps_log_error "Missing clash template: ${template}"
    return 1
  fi

  local proxies_block=""
  local names_block=""

  while IFS= read -r stack; do
    local rendered name
    rendered="$(ps_sub_clash_proxy_from_stack "${stack}")"
    name="$(jq -r '.name' <<<"${stack}")"

    if [[ -n "${rendered}" ]]; then
      proxies_block+="${rendered}"
      proxies_block+=$'\n'
      names_block+="      - \"$(ps_sub_yaml_escape "${name}")\""
      names_block+=$'\n'
    fi
  done < <(jq -c '.stacks[]? | select(.enabled == true)' "${PS_MANIFEST}")

  if [[ -z "${proxies_block}" ]]; then
    proxies_block="  - name: \"DIRECT\"\n    type: direct\n"
    names_block="      - \"DIRECT\"\n"
  fi

  awk \
    -v proxies="${proxies_block}" \
    -v names="${names_block}" \
    'BEGIN{gsub(/\\n/,"\n",proxies); gsub(/\\n/,"\n",names)}
     {gsub(/__PROXIES__/,proxies); gsub(/__PROXY_NAMES__/,names); print}' \
    "${template}" >"${out_file}"

  ps_sub_record_export "clash-meta" "${out_file}"
  ps_log_success "Clash.Meta exported: ${out_file}"
  ps_log_info "Initialized rules prepared: ${root}/clash/rules"
}

ps_sub_export_xray_client_config() {
  ps_print_header "Export Xray Client Config"

  local root="${1:-}"
  [[ -z "${root}" ]] && root="$(ps_sub_create_export_root "xray-client")"
  ps_sub_prepare_bundle_dirs "${root}" || return 1
  ps_sub_write_initialized_rules_bundle "${root}" || return 1

  local count=0
  local first_file=""

  while IFS= read -r stack; do
    local stack_id name server port uuid flow security transport sni fingerprint
    local reality_server_name reality_fingerprint reality_public_key reality_short_id
    local grpc_service xhttp_path xhttp_host out_file

    stack_id="$(jq -r '.stack_id' <<<"${stack}")"
    name="$(jq -r '.name' <<<"${stack}")"
    server="$(jq -r '.server' <<<"${stack}")"
    port="$(jq -r '.port' <<<"${stack}")"
    uuid="$(jq -r '.uuid' <<<"${stack}")"
    flow="$(jq -r '.flow // ""' <<<"${stack}")"
    security="$(jq -r '.security // "tls"' <<<"${stack}")"
    transport="$(jq -r '.transport // "tcp"' <<<"${stack}")"
    sni="$(jq -r '.sni // .server' <<<"${stack}")"
    fingerprint="$(jq -r '.fingerprint // "chrome"' <<<"${stack}")"
    reality_server_name="$(jq -r '.reality.server_name // .sni // .server' <<<"${stack}")"
    reality_fingerprint="$(jq -r '.reality.fingerprint // .fingerprint // "chrome"' <<<"${stack}")"
    reality_public_key="$(jq -r '.reality.public_key // ""' <<<"${stack}")"
    reality_short_id="$(jq -r '.reality.short_id // ""' <<<"${stack}")"
    grpc_service="$(jq -r '.grpc.service_name // "grpc"' <<<"${stack}")"
    xhttp_path="$(jq -r '.xhttp.path // "/"' <<<"${stack}")"
    xhttp_host="$(jq -r '.xhttp.host // ""' <<<"${stack}")"

    out_file="${root}/xray/client-${stack_id}.json"

    jq -n \
      --arg name "${name}" \
      --arg server "${server}" \
      --argjson port "${port}" \
      --arg uuid "${uuid}" \
      --arg flow "${flow}" \
      --arg security "${security}" \
      --arg transport "${transport}" \
      --arg sni "${sni}" \
      --arg fingerprint "${fingerprint}" \
      --arg reality_server_name "${reality_server_name}" \
      --arg reality_fingerprint "${reality_fingerprint}" \
      --arg reality_public_key "${reality_public_key}" \
      --arg reality_short_id "${reality_short_id}" \
      --arg grpc_service "${grpc_service}" \
      --arg xhttp_path "${xhttp_path}" \
      --arg xhttp_host "${xhttp_host}" \
      '{
        log: {loglevel:"warning"},
        inbounds: [
          {
            tag:"socks-in",
            listen:"127.0.0.1",
            port:10808,
            protocol:"socks",
            settings:{udp:true}
          }
        ],
        outbounds: [
          {
            tag:"proxy",
            protocol:"vless",
            settings:{
              vnext:[
                {
                  address:$server,
                  port:$port,
                  users:[
                    (
                      {id:$uuid,encryption:"none"}
                      + (if $flow != "" then {flow:$flow} else {} end)
                    )
                  ]
                }
              ]
            },
            streamSettings:(
              {
                network:(if $transport == "grpc" then "grpc" elif $transport == "xhttp" then "xhttp" else "tcp" end),
                security:(if $security == "reality" then "reality" elif $security == "tls" then "tls" else "none" end)
              }
              + (if $transport == "grpc" then {grpcSettings:{serviceName:$grpc_service}} else {} end)
              + (if $transport == "xhttp" then
                  ({xhttpSettings:{path:$xhttp_path}}
                   + (if $xhttp_host != "" then {xhttpSettings:{path:$xhttp_path,host:$xhttp_host}} else {} end))
                 else {} end)
              + (if $security == "tls" then
                  {tlsSettings:{serverName:$sni,fingerprint:$fingerprint}}
                 elif $security == "reality" then
                  {
                    realitySettings:(
                      {serverName:$reality_server_name,fingerprint:$reality_fingerprint}
                      + (if $reality_public_key != "" then {publicKey:$reality_public_key} else {} end)
                      + (if $reality_short_id != "" then {shortId:$reality_short_id} else {} end)
                    )
                  }
                 else {} end)
            )
          },
          {tag:"direct", protocol:"freedom"},
          {tag:"block", protocol:"blackhole"}
        ],
        routing:{
          domainStrategy:"AsIs",
          rules:[
            {type:"field", ip:["geoip:private"], outboundTag:"direct"},
            {type:"field", domain:["geosite:cn"], outboundTag:"direct"},
            {type:"field", ip:["geoip:cn"], outboundTag:"direct"},
            {type:"field", domain:["domain:doubleclick.net","domain:app-measurement.com"], outboundTag:"block"},
            {type:"field", inboundTag:["socks-in"], outboundTag:"proxy"}
          ]
        }
      }' >"${out_file}"

    ps_sub_record_export "xray-client" "${out_file}"
    [[ -z "${first_file}" ]] && first_file="${out_file}"
    count=$((count + 1))
  done < <(jq -c '.stacks[]? | select(.enabled == true and .protocol == "vless")' "${PS_MANIFEST}")

  if (( count == 0 )); then
    ps_log_warn "No enabled VLESS stack for Xray client export"
    return 1
  fi

  cp "${first_file}" "${root}/xray/client.json"
  ps_sub_record_export "xray-client" "${root}/xray/client.json"
  ps_log_success "Xray client configs exported: ${root}/xray"
  ps_log_info "Initialized rules prepared: ${root}/rules"
}

ps_sub_export_singbox_client_config() {
  ps_print_header "Export sing-box Client Config"

  local root="${1:-}"
  [[ -z "${root}" ]] && root="$(ps_sub_create_export_root "singbox-client")"
  ps_sub_prepare_bundle_dirs "${root}" || return 1
  ps_sub_write_initialized_rules_bundle "${root}" || return 1

  local count=0
  local first_file=""

  while IFS= read -r stack; do
    local stack_id name server port uuid flow security transport sni fingerprint
    local reality_server_name reality_public_key reality_short_id
    local grpc_service xhttp_path xhttp_host out_file

    stack_id="$(jq -r '.stack_id' <<<"${stack}")"
    name="$(jq -r '.name' <<<"${stack}")"
    server="$(jq -r '.server' <<<"${stack}")"
    port="$(jq -r '.port' <<<"${stack}")"
    uuid="$(jq -r '.uuid' <<<"${stack}")"
    flow="$(jq -r '.flow // ""' <<<"${stack}")"
    security="$(jq -r '.security // "tls"' <<<"${stack}")"
    transport="$(jq -r '.transport // "tcp"' <<<"${stack}")"
    sni="$(jq -r '.sni // .server' <<<"${stack}")"
    fingerprint="$(jq -r '.fingerprint // "chrome"' <<<"${stack}")"
    reality_server_name="$(jq -r '.reality.server_name // .sni // .server' <<<"${stack}")"
    reality_public_key="$(jq -r '.reality.public_key // ""' <<<"${stack}")"
    reality_short_id="$(jq -r '.reality.short_id // ""' <<<"${stack}")"
    grpc_service="$(jq -r '.grpc.service_name // "grpc"' <<<"${stack}")"
    xhttp_path="$(jq -r '.xhttp.path // "/"' <<<"${stack}")"
    xhttp_host="$(jq -r '.xhttp.host // ""' <<<"${stack}")"

    out_file="${root}/singbox/client-${stack_id}.json"

    jq -n \
      --arg name "${name}" \
      --arg server "${server}" \
      --argjson port "${port}" \
      --arg uuid "${uuid}" \
      --arg flow "${flow}" \
      --arg security "${security}" \
      --arg transport "${transport}" \
      --arg sni "${sni}" \
      --arg fingerprint "${fingerprint}" \
      --arg reality_server_name "${reality_server_name}" \
      --arg reality_public_key "${reality_public_key}" \
      --arg reality_short_id "${reality_short_id}" \
      --arg grpc_service "${grpc_service}" \
      --arg xhttp_path "${xhttp_path}" \
      --arg xhttp_host "${xhttp_host}" \
      '{
        log: {level:"warn", timestamp:true},
        inbounds: [
          {
            type:"mixed",
            tag:"mixed-in",
            listen:"127.0.0.1",
            listen_port:10808
          }
        ],
        outbounds: [
          (
            {
              type:"vless",
              tag:"proxy",
              server:$server,
              server_port:$port,
              uuid:$uuid,
              tls:(
                if $security == "none" then
                  {enabled:false}
                else
                  (
                    {
                      enabled:true,
                      server_name:(if $security == "reality" then $reality_server_name else $sni end),
                      utls:{enabled:true,fingerprint:$fingerprint}
                    }
                    + (if $security == "reality" then
                        {
                          reality:(
                            {enabled:true}
                            + (if $reality_public_key != "" then {public_key:$reality_public_key} else {} end)
                            + (if $reality_short_id != "" then {short_id:$reality_short_id} else {} end)
                          )
                        }
                       else {} end)
                  )
                end
              ),
              transport:(
                if $transport == "grpc" then
                  {type:"grpc",service_name:$grpc_service}
                elif $transport == "xhttp" then
                  ({type:"http",path:$xhttp_path}
                   + (if $xhttp_host != "" then {host:[$xhttp_host]} else {} end))
                else
                  {type:"tcp"}
                end
              )
            }
            + (if $flow != "" then {flow:$flow} else {} end)
          ),
          {type:"direct", tag:"direct"},
          {type:"block", tag:"block"}
        ],
        route: {
          rules: [
            {
              ip_cidr:["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8","169.254.0.0/16","100.64.0.0/10","::1/128","fc00::/7","fe80::/10"],
              outbound:"direct"
            },
            {geoip:["cn"], outbound:"direct"},
            {geosite:["cn"], outbound:"direct"},
            {domain_suffix:["doubleclick.net","app-measurement.com"], outbound:"block"},
            {inbound:["mixed-in"], outbound:"proxy"}
          ],
          final:"proxy"
        }
      }' >"${out_file}"

    ps_sub_record_export "singbox-client" "${out_file}"
    [[ -z "${first_file}" ]] && first_file="${out_file}"
    count=$((count + 1))
  done < <(jq -c '.stacks[]? | select(.enabled == true and .protocol == "vless")' "${PS_MANIFEST}")

  if (( count == 0 )); then
    ps_log_warn "No enabled VLESS stack for sing-box client export"
    return 1
  fi

  cp "${first_file}" "${root}/singbox/client.json"
  ps_sub_record_export "singbox-client" "${root}/singbox/client.json"
  ps_log_success "sing-box client configs exported: ${root}/singbox"
  ps_log_info "Initialized rules prepared: ${root}/rules"
}

ps_sub_export_local_proxy_templates() {
  ps_print_header "Export Local Proxy Templates with Routing"

  local root="${1:-}"
  [[ -z "${root}" ]] && root="$(ps_sub_create_export_root "local-proxy")"
  ps_sub_prepare_bundle_dirs "${root}" || return 1

  local out_file="${root}/local-proxy-routing-template.md"

  cat >"${out_file}" <<EOF
# Local Proxy Routing Template

## Suggested forwarding examples

- local SOCKS/HTTP/Mixed inbound -> socks5 upstream
- local SOCKS/HTTP/Mixed inbound -> remote VLESS
- local inbound -> direct
- local inbound -> block

## Current inbounds
$(jq -r '.inbounds[]? | "- \(.tag) type=\(.type) listen=\(.listen):\(.port)"' "${PS_MANIFEST}")

## Current outbounds
$(jq -r '.outbounds[]? | "- \(.tag) type=\(.type)"' "${PS_MANIFEST}")

## Current routes (priority order)
$(jq -r '.routes | sort_by(.priority)[] | "- [\(.priority)] \(.name) => \(.outbound)"' "${PS_MANIFEST}")
EOF

  ps_sub_record_export "local-proxy-template" "${out_file}"
  ps_log_success "Local proxy template exported: ${out_file}"
}

ps_sub_export_client_with_rules_bundle() {
  ps_print_header "Export Client Config + Initialized Rules Bundle"

  local root="$(ps_sub_create_export_root "client-rules-bundle")"
  local failures=0
  local failed_steps=()

  ps_sub_export_initialized_rules_bundle "${root}" || { failures=$((failures + 1)); failed_steps+=("initialized-rules-bundle"); }
  ps_sub_generate_share_links "${root}" || { failures=$((failures + 1)); failed_steps+=("share-links"); }
  ps_sub_generate_base64_subscription "${root}" || { failures=$((failures + 1)); failed_steps+=("base64-subscription"); }
  ps_sub_export_clash_meta "${root}" || { failures=$((failures + 1)); failed_steps+=("clash-meta"); }
  ps_sub_export_xray_client_config "${root}" || { failures=$((failures + 1)); failed_steps+=("xray-client"); }
  ps_sub_export_singbox_client_config "${root}" || { failures=$((failures + 1)); failed_steps+=("singbox-client"); }
  ps_sub_export_local_proxy_templates "${root}" || { failures=$((failures + 1)); failed_steps+=("local-proxy-template"); }

  if (( failures == 7 )); then
    ps_log_error "Client config + rules bundle export failed"
    return 1
  fi

  if (( failures > 0 )); then
    ps_log_warn "Client config + rules bundle exported with partial failures"
    ps_log_warn "Failed steps: ${failed_steps[*]}"
  fi

  ps_sub_record_export "client-rules-bundle" "${root}"
  ps_log_success "Client config + initialized rules bundle exported: ${root}"
}
