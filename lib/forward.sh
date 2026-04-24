#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_FORWARD_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_FORWARD_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"
# shellcheck source=lib/crypto.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/crypto.sh"

ps_forward_pick_id() {
  mapfile -t rows < <(jq -r '.forwardings[]? | "\(.forward_id)|\(.name)|\(.inbound_tag)|\(.outbound_tag)|\(.listen_port)|\(.enabled)"' "${PS_MANIFEST}")
  if [[ "${#rows[@]}" -eq 0 ]]; then
    ps_log_warn "未找到转发条目。"
    return 1
  fi

  local i=1 row
  printf "\n"
  for row in "${rows[@]}"; do
    IFS='|' read -r fid name inbound_tag outbound_tag listen_port enabled <<<"${row}"
    printf "%d) %s id=%s listen=%s outbound=%s 启用=%s\n" "${i}" "${name}" "${fid}" "${listen_port}" "${outbound_tag}" "${enabled}"
    i=$((i + 1))
  done

  local choice
  choice="$(ps_prompt_required "请选择转发编号")"
  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#rows[@]})); then
    ps_log_error "转发选择无效"
    return 1
  fi

  IFS='|' read -r fid _ <<<"${rows[choice-1]}"
  printf "%s" "${fid}"
}

ps_forward_pick_existing_outbound() {
  mapfile -t rows < <(jq -r '.outbounds[]? | select(.enabled != false) | "\(.tag)|\(.type)|\(.server // "-")|\(.port // 0)"' "${PS_MANIFEST}")
  if [[ "${#rows[@]}" -eq 0 ]]; then
    ps_log_warn "未找到已启用的出站。"
    return 1
  fi

  local i=1 row
  for row in "${rows[@]}"; do
    IFS='|' read -r tag type server port <<<"${row}"
    printf "%d) %s type=%s target=%s:%s\n" "${i}" "${tag}" "${type}" "${server}" "${port}"
    i=$((i + 1))
  done

  local choice
  choice="$(ps_prompt_required "请选择出站编号")"
  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#rows[@]})); then
    ps_log_error "出站选择无效"
    return 1
  fi

  IFS='|' read -r tag _ <<<"${rows[choice-1]}"
  printf "%s" "${tag}"
}

ps_forward_generate_unique_outbound_tag() {
  local prefix="${1:-fwd-out}"
  local tag
  while true; do
    tag="${prefix}-$(ps_generate_id tmp | awk -F'-' '{print $NF}')"
    if ! ps_manifest_array_has '.outbounds' 'tag' "${tag}"; then
      printf "%s" "${tag}"
      return 0
    fi
  done
}

ps_forward_create_new_outbound_json() {
  local forward_id="${1}"

  printf "1) direct\n"
  printf "2) block\n"
  printf "3) socks5 上游\n"
  printf "4) http 上游\n"
  printf "5) vless 远端\n"
  printf "6) shadowsocks 远端\n"

  local type_choice type
  type_choice="$(ps_prompt_required "新出站类型编号")"
  case "${type_choice}" in
    1) type="direct" ;;
    2) type="block" ;;
    3) type="socks5" ;;
    4) type="http" ;;
    5) type="vless" ;;
    6) type="shadowsocks" ;;
    *) ps_log_error "出站类型无效"; return 1 ;;
  esac

  local tag server="" port="0" username="" password="" network="tcp" sni="" uuid="" method=""
  tag="$(ps_forward_generate_unique_outbound_tag "fwd-${type}")"

  if [[ "${type}" =~ ^(socks5|http|vless|shadowsocks)$ ]]; then
    server="$(ps_prompt_required "目标服务器")"
    port="$(ps_prompt_required "目标端口")"
    if ! ps_validate_port "${port}"; then
      ps_log_error "目标端口无效"
      return 1
    fi
  fi

  case "${type}" in
    socks5|http)
      username="$(ps_prompt "用户名（可选）" "")"
      password="$(ps_prompt "密码（可选）" "")"
      ;;
    vless)
      uuid="$(ps_prompt "UUID" "$(ps_generate_uuid)")"
      sni="$(ps_prompt "SNI" "${server}")"
      network="$(ps_prompt "网络（tcp/grpc/ws）" "tcp")"
      ;;
    shadowsocks)
      method="$(ps_prompt "加密方法" "2022-blake3-aes-128-gcm")"
      password="$(ps_prompt "密码" "$(ps_generate_ss2022_password)")"
      ;;
  esac

  jq -n \
    --arg tag "${tag}" \
    --arg type "${type}" \
    --arg server "${server}" \
    --argjson port "${port}" \
    --arg username "${username}" \
    --arg password "${password}" \
    --arg network "${network}" \
    --arg sni "${sni}" \
    --arg uuid "${uuid}" \
    --arg method "${method}" \
    --arg forward_id "${forward_id}" \
    --arg created_at "$(ps_now_iso)" \
    '{
      tag:$tag,
      type:$type,
      server:$server,
      port:$port,
      auth:{username:$username,password:$password},
      network:$network,
      sni:$sni,
      uuid:$uuid,
      method:$method,
      password:$password,
      members:[],
      enabled:true,
      managed_by:("forward:" + $forward_id),
      created_at:$created_at,
      updated_at:$created_at
    }'
}

ps_forward_list() {
  ps_print_header "转发条目"
  jq -r '
    if (.forwardings | length) == 0 then
      "未配置转发条目。"
    else
      (.forwardings[] |
        "- [\(.forward_id)] \(.name) inbound=\(.inbound_tag)(\(.listen):\(.listen_port)) outbound=\(.outbound_tag) target=\(.target_host // "-"):\(.target_port // 0) network=\(.network|join(",")) 启用=\(.enabled)")
    end
  ' "${PS_MANIFEST}"
}

ps_forward_create() {
  ps_print_header "创建转发条目"

  local forward_id name inbound_type listen listen_port udp priority network_mode network_csv
  forward_id="$(ps_generate_id fwd)"
  name="$(ps_prompt "转发名称" "forward-${forward_id}")"

  printf "1) SOCKS5\n2) HTTP\n3) Mixed\n"
  case "$(ps_prompt_required "本地入站类型编号")" in
    1) inbound_type="socks" ;;
    2) inbound_type="http" ;;
    3) inbound_type="mixed" ;;
    *) ps_log_error "入站类型无效"; return 1 ;;
  esac

  listen="$(ps_prompt "本地监听地址" "127.0.0.1")"
  listen_port="$(ps_prompt_for_port "本地监听端口（输入端口，回车随机）")"
  udp="$(ps_prompt "启用 UDP（true/false）" "true")"
  priority="$(ps_prompt "路由优先级（越小越优先）" "90")"

  if ! [[ "${priority}" =~ ^[0-9]+$ ]]; then
    ps_log_error "优先级无效"
    return 1
  fi

  network_mode="$(ps_prompt "网络（tcp/udp/both）" "both")"
  case "${network_mode}" in
    tcp|TCP) network_csv="tcp" ;;
    udp|UDP) network_csv="udp" ;;
    both|BOTH|"") network_csv="tcp,udp" ;;
    *) network_csv="tcp,udp" ;;
  esac

  local outbound_choice outbound_tag outbound_json="" target_host="" target_port="0"
  printf "1) 使用现有出站\n2) 为该转发创建出站\n"
  outbound_choice="$(ps_prompt_required "请选择")"
  case "${outbound_choice}" in
    1)
      outbound_tag="$(ps_forward_pick_existing_outbound)" || return 1
      target_host="$(jq -r --arg tag "${outbound_tag}" '.outbounds[] | select(.tag == $tag) | .server // ""' "${PS_MANIFEST}")"
      target_port="$(jq -r --arg tag "${outbound_tag}" '.outbounds[] | select(.tag == $tag) | .port // 0' "${PS_MANIFEST}")"
      ;;
    2)
      outbound_json="$(ps_forward_create_new_outbound_json "${forward_id}")" || return 1
      outbound_tag="$(jq -r '.tag' <<<"${outbound_json}")"
      target_host="$(jq -r '.server // ""' <<<"${outbound_json}")"
      target_port="$(jq -r '.port // 0' <<<"${outbound_json}")"
      ;;
    *)
      ps_log_error "选择无效"
      return 1
      ;;
  esac

  local inbound_tag route_name
  inbound_tag="fwd-in-${forward_id}"
  route_name="fwd-route-${forward_id}"

  local inbound_json route_json forwarding_json
  inbound_json="$(jq -n \
    --arg tag "${inbound_tag}" \
    --arg type "${inbound_type}" \
    --arg listen "${listen}" \
    --argjson port "${listen_port}" \
    --argjson udp "${udp}" \
    --arg forward_id "${forward_id}" \
    --arg created_at "$(ps_now_iso)" \
    '{tag:$tag,type:$type,listen:$listen,port:$port,auth:{},udp:$udp,stack_id:"",public:false,enabled:true,managed_by:("forward:" + $forward_id),created_at:$created_at,updated_at:$created_at}')"

  route_json="$(jq -n \
    --arg name "${route_name}" \
    --argjson priority "${priority}" \
    --arg inbound_tag "${inbound_tag}" \
    --argjson network "$(ps_csv_to_json_array "${network_csv}")" \
    --arg outbound "${outbound_tag}" \
    --arg forward_id "${forward_id}" \
    --arg created_at "$(ps_now_iso)" \
    '{name:$name,priority:$priority,inbound_tag:[$inbound_tag],domain_suffix:[],domain_keyword:[],ip_cidr:[],network:$network,outbound:$outbound,enabled:true,forwarding:true,managed_by:("forward:" + $forward_id),created_at:$created_at,updated_at:$created_at}')"

  forwarding_json="$(jq -n \
    --arg forward_id "${forward_id}" \
    --arg name "${name}" \
    --arg inbound_tag "${inbound_tag}" \
    --arg inbound_type "${inbound_type}" \
    --arg listen "${listen}" \
    --argjson listen_port "${listen_port}" \
    --arg outbound_tag "${outbound_tag}" \
    --arg target_host "${target_host}" \
    --argjson target_port "${target_port}" \
    --argjson network "$(ps_csv_to_json_array "${network_csv}")" \
    --arg route_name "${route_name}" \
    --arg created_at "$(ps_now_iso)" \
    '{
      forward_id:$forward_id,
      name:$name,
      inbound_tag:$inbound_tag,
      inbound_type:$inbound_type,
      listen:$listen,
      listen_port:$listen_port,
      outbound_tag:$outbound_tag,
      target_host:$target_host,
      target_port:$target_port,
      network:$network,
      route_name:$route_name,
      enabled:true,
      created_at:$created_at,
      updated_at:$created_at
    }')"

  ps_manifest_update --argjson inbound "${inbound_json}" --arg ts "$(ps_now_iso)" '.inbounds += [$inbound] | .meta.updated_at = $ts'

  if [[ -n "${outbound_json}" ]]; then
    ps_manifest_update --argjson outbound "${outbound_json}" --arg ts "$(ps_now_iso)" '.outbounds += [$outbound] | .meta.updated_at = $ts'
  fi

  ps_manifest_update --argjson route "${route_json}" --arg ts "$(ps_now_iso)" '.routes += [$route] | .meta.updated_at = $ts'
  ps_manifest_update --argjson forwarding "${forwarding_json}" --arg ts "$(ps_now_iso)" '.forwardings += [$forwarding] | .meta.updated_at = $ts'

  ps_log_success "转发已创建： ${name}"
  ps_log_info "转发监听地址： ${listen}:${listen_port}"
  ps_log_info "转发出站： ${outbound_tag} (${target_host}:${target_port})"
}

ps_forward_delete() {
  ps_print_header "删除转发条目"

  local forward_id
  forward_id="$(ps_forward_pick_id)" || return 1

  if ! ps_confirm "删除转发 ${forward_id} 及关联入站/路由/出站吗？" "N"; then
    ps_log_info "已取消"
    return 0
  fi

  ps_manifest_update --arg forward_id "${forward_id}" --arg ts "$(ps_now_iso)" '
    .forwardings |= map(select(.forward_id != $forward_id))
    | .routes |= map(select((.managed_by // "") != ("forward:" + $forward_id)))
    | .inbounds |= map(select((.managed_by // "") != ("forward:" + $forward_id)))
    | .outbounds |= map(select((.managed_by // "") != ("forward:" + $forward_id)))
    | .meta.updated_at = $ts
  '

  ps_log_success "转发已删除： ${forward_id}"
}
