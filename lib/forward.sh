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
    ps_log_warn "未找到转发链。"
    return 1
  fi

  local i=1 row
  printf "\n" >&2
  for row in "${rows[@]}"; do
    IFS='|' read -r fid name inbound_tag outbound_tag listen_port enabled <<<"${row}"
    printf "%d) %s id=%s 入口=%s 端口=%s 出口=%s 启用=%s\n" "${i}" "${name}" "${fid}" "${inbound_tag}" "${listen_port}" "${outbound_tag}" "${enabled}" >&2
    i=$((i + 1))
  done

  local choice
  choice="$(ps_prompt_required "请选择转发链编号")"
  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#rows[@]})); then
    ps_log_error "转发链选择无效"
    return 1
  fi

  IFS='|' read -r fid _ <<<"${rows[choice-1]}"
  printf "%s" "${fid}"
}

ps_forward_pick_existing_outbound() {
  mapfile -t rows < <(jq -r '.outbounds[]? | select(.enabled != false) | "\(.tag)|\(.type)|\(.server // "-")|\(.port // 0)"' "${PS_MANIFEST}")
  if [[ "${#rows[@]}" -eq 0 ]]; then
    ps_log_warn "未找到已启用的上游出口。"
    return 1
  fi

  local i=1 row
  for row in "${rows[@]}"; do
    IFS='|' read -r tag type server port <<<"${row}"
    printf "%d) %s type=%s target=%s:%s\n" "${i}" "${tag}" "${type}" "${server}" "${port}" >&2
    i=$((i + 1))
  done

  local choice
  choice="$(ps_prompt_required "请选择上游出口编号")"
  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#rows[@]})); then
    ps_log_error "上游出口选择无效"
    return 1
  fi

  IFS='|' read -r tag _ <<<"${rows[choice-1]}"
  printf "%s" "${tag}"
}

ps_forward_pick_existing_local_inbound() {
  mapfile -t rows < <(jq -r '.inbounds[]? | select(.public != true) | "\(.tag)|\(.type)|\(.listen):\(.port)|\(.enabled)"' "${PS_MANIFEST}")
  if [[ "${#rows[@]}" -eq 0 ]]; then
    return 1
  fi

  local i=1 row
  printf "\n" >&2
  for row in "${rows[@]}"; do
    IFS='|' read -r tag type endpoint enabled <<<"${row}"
    printf "%d) %s type=%s endpoint=%s 启用=%s\n" "${i}" "${tag}" "${type}" "${endpoint}" "${enabled}" >&2
    i=$((i + 1))
  done

  local choice
  choice="$(ps_prompt_required "请选择本地入口编号")"
  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#rows[@]})); then
    ps_log_error "本地入口选择无效"
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
  type_choice="$(ps_prompt_required "新上游类型编号")"
  case "${type_choice}" in
    1) type="direct" ;;
    2) type="block" ;;
    3) type="socks5" ;;
    4) type="http" ;;
    5) type="vless" ;;
    6) type="shadowsocks" ;;
    *) ps_log_error "上游类型无效"; return 1 ;;
  esac

  local tag server="" port="0" username="" password="" network="tcp" sni="" uuid="" method=""
  tag="$(ps_forward_generate_unique_outbound_tag "fwd-${type}")"

  if [[ "${type}" =~ ^(socks5|http|vless|shadowsocks)$ ]]; then
    server="$(ps_prompt_required "目标地址")"
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
  ps_print_header "转发链列表"
  jq -r '
    if (.forwardings | length) == 0 then
      "未配置转发链。"
    else
      (.forwardings[] |
        "- [" + (.forward_id // "-") + "] " + (.name // "-")
        + " | 入口=" + (.inbound_tag // "-") + "(" + ((.listen // "-") + ":" + ((.listen_port // "-")|tostring)) + ")"
        + " | 出口=" + (.outbound_tag // "direct")
        + " | 规则=" + (.route_name // "-")
        + " | 启用=" + ((.enabled // true)|tostring)
      )
    end
  ' "${PS_MANIFEST}"
}

ps_forward_inspect_health() {
  ps_print_header "转发/路由绑定诊断"
  jq -r '
    if (.forwardings | length) == 0 then
      "未配置转发链。"
    else
      .forwardings[] |
      (
        . as $f
        | ([.inbounds[]? | select(.tag == $f.inbound_tag)] | length) as $in_ok
        | ([.outbounds[]? | select(.tag == $f.outbound_tag)] | length) as $out_ok
        | ([.routes[]? | select(.name == $f.route_name)] | length) as $rule_ok
        | "- " + ($f.name // $f.forward_id // "-")
          + " | 入口有效=" + (($in_ok > 0)|tostring)
          + " | 出口有效=" + (($out_ok > 0)|tostring)
          + " | 规则有效=" + (($rule_ok > 0)|tostring)
      )
    end
  ' "${PS_MANIFEST}"
}

ps_forward_create() {
  ps_print_header "创建转发链"
  printf "说明：转发链 = 本地入口 + 上游出口 + 路由绑定。\n"

  local forward_id name priority network_mode network_csv
  forward_id="$(ps_generate_id fwd)"
  name="$(ps_prompt "转发链名称" "forward-${forward_id}")"
  priority="$(ps_prompt "关联路由优先级（越小越优先）" "90")"
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

  local inbound_choice inbound_tag inbound_type listen listen_port udp
  printf "1) 复用现有本地入口\n"
  printf "2) 新建本地入口\n"
  inbound_choice="$(ps_prompt_required "请选择")"
  case "${inbound_choice}" in
    1)
      inbound_tag="$(ps_forward_pick_existing_local_inbound)" || {
        ps_log_warn "没有可复用本地入口，将改为新建。"
        inbound_choice=2
      }
      ;;
    2) ;;
    *) ps_log_error "选择无效"; return 1 ;;
  esac

  local inbound_json=""
  if [[ "${inbound_choice}" == "2" ]]; then
    printf "1) SOCKS5\n2) HTTP\n3) Mixed\n"
    case "$(ps_prompt_required "本地入口类型编号")" in
      1) inbound_type="socks" ;;
      2) inbound_type="http" ;;
      3) inbound_type="mixed" ;;
      *) ps_log_error "入口类型无效"; return 1 ;;
    esac

    listen="$(ps_prompt "本地监听地址" "127.0.0.1")"
    listen_port="$(ps_prompt_for_port "本地监听端口（回车自动分配）")"
    udp="$(ps_prompt "启用 UDP（true/false）" "true")"
    inbound_tag="fwd-in-${forward_id}"

    inbound_json="$(jq -n \
      --arg tag "${inbound_tag}" \
      --arg type "${inbound_type}" \
      --arg listen "${listen}" \
      --argjson port "${listen_port}" \
      --argjson udp "${udp}" \
      --arg forward_id "${forward_id}" \
      --arg created_at "$(ps_now_iso)" \
      '{tag:$tag,type:$type,listen:$listen,port:$port,auth:{},udp:$udp,stack_id:"",public:false,enabled:true,managed_by:("forward:" + $forward_id),created_at:$created_at,updated_at:$created_at}')"
  else
    listen="$(jq -r --arg t "${inbound_tag}" '.inbounds[] | select(.tag==$t) | .listen // "127.0.0.1"' "${PS_MANIFEST}")"
    listen_port="$(jq -r --arg t "${inbound_tag}" '.inbounds[] | select(.tag==$t) | .port // 0' "${PS_MANIFEST}")"
  fi

  local outbound_choice outbound_tag outbound_json="" target_host="" target_port="0"
  printf "1) 使用现有上游出口\n2) 为该转发链创建上游出口\n"
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

  local route_name route_json forwarding_json
  route_name="fwd-route-${forward_id}"
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
    --arg listen "${listen}" \
    --argjson listen_port "${listen_port}" \
    --arg outbound_tag "${outbound_tag}" \
    --arg target_host "${target_host}" \
    --argjson target_port "${target_port}" \
    --argjson network "$(ps_csv_to_json_array "${network_csv}")" \
    --arg route_name "${route_name}" \
    --arg created_at "$(ps_now_iso)" \
    '{forward_id:$forward_id,name:$name,inbound_tag:$inbound_tag,listen:$listen,listen_port:$listen_port,outbound_tag:$outbound_tag,target_host:$target_host,target_port:$target_port,network:$network,route_name:$route_name,enabled:true,created_at:$created_at,updated_at:$created_at}')"

  if [[ -n "${inbound_json}" ]]; then
    ps_manifest_update --argjson inbound "${inbound_json}" --arg ts "$(ps_now_iso)" '.inbounds += [$inbound] | .meta.updated_at = $ts'
  fi
  if [[ -n "${outbound_json}" ]]; then
    ps_manifest_update --argjson outbound "${outbound_json}" --arg ts "$(ps_now_iso)" '.outbounds += [$outbound] | .meta.updated_at = $ts'
  fi

  ps_manifest_update --argjson route "${route_json}" --arg ts "$(ps_now_iso)" '.routes += [$route] | .meta.updated_at = $ts'
  ps_manifest_update --argjson forwarding "${forwarding_json}" --arg ts "$(ps_now_iso)" '.forwardings += [$forwarding] | .meta.updated_at = $ts'

  ps_log_success "转发链已创建： ${name}"
  printf "摘要：名称=%s | 本地入口=%s:%s | 上游=%s | 规则=%s | 启用=true\n" "${name}" "${listen}" "${listen_port}" "${outbound_tag}" "${route_name}"
  printf "流量路径：入口（%s） -> 规则（%s） -> 出口（%s）。\n" "${inbound_tag}" "${route_name}" "${outbound_tag}"
  printf "下一步建议：\n"
  printf -- "- 可前往“路由规则”细化域名/IP 匹配条件\n"
  printf -- "- 可前往“运行状态与诊断”检查监听与应用状态\n"
}

ps_forward_edit() {
  ps_print_header "编辑转发链"
  local forward_id
  forward_id="$(ps_forward_pick_id)" || return 1

  local name enabled change_outbound outbound_tag target_host target_port
  name="$(ps_prompt "名称（留空保持）" "")"
  enabled="$(ps_prompt "启用状态 true/false（留空保持）" "")"
  change_outbound="$(ps_prompt "是否变更上游出口（true/false）" "false")"
  outbound_tag=""
  target_host=""
  target_port="0"
  if [[ "${change_outbound}" == "true" ]]; then
    outbound_tag="$(ps_forward_pick_existing_outbound)" || return 1
    target_host="$(jq -r --arg tag "${outbound_tag}" '.outbounds[] | select(.tag == $tag) | .server // ""' "${PS_MANIFEST}")"
    target_port="$(jq -r --arg tag "${outbound_tag}" '.outbounds[] | select(.tag == $tag) | .port // 0' "${PS_MANIFEST}")"
  fi

  local jq_filter='.forwardings |= map(if .forward_id == $fid then . else . end)'
  [[ -n "${name}" ]] && jq_filter+=' | .forwardings |= map(if .forward_id == $fid then .name = $name else . end)'
  [[ -n "${enabled}" ]] && jq_filter+=' | .forwardings |= map(if .forward_id == $fid then .enabled = ($enabled == "true") else . end)'
  [[ -n "${outbound_tag}" ]] && jq_filter+=' | .forwardings |= map(if .forward_id == $fid then .outbound_tag = $outbound_tag | .target_host = $target_host | .target_port = ($target_port|tonumber) else . end)'
  jq_filter+=' | .forwardings |= map(if .forward_id == $fid then .updated_at = $ts else . end)'
  [[ -n "${outbound_tag}" ]] && jq_filter+=' | .routes |= map(if ((.managed_by // "") == ("forward:" + $fid)) then .outbound = $outbound_tag | .updated_at = $ts else . end)'
  jq_filter+=' | .meta.updated_at = $ts'

  ps_manifest_update \
    --arg fid "${forward_id}" \
    --arg name "${name}" \
    --arg enabled "${enabled}" \
    --arg outbound_tag "${outbound_tag}" \
    --arg target_host "${target_host}" \
    --arg target_port "${target_port}" \
    --arg ts "$(ps_now_iso)" \
    "${jq_filter}"

  ps_log_success "转发链已更新： ${forward_id}"
}

ps_forward_toggle() {
  ps_print_header "启用/禁用转发链"
  local forward_id
  forward_id="$(ps_forward_pick_id)" || return 1

  local current next
  current="$(jq -r --arg fid "${forward_id}" '.forwardings[] | select(.forward_id==$fid) | (.enabled // true)' "${PS_MANIFEST}")"
  if [[ "${current}" == "true" ]]; then next="false"; else next="true"; fi

  ps_manifest_update --arg fid "${forward_id}" --arg next "${next}" --arg ts "$(ps_now_iso)" '
    .forwardings |= map(if .forward_id == $fid then .enabled = ($next == "true") | .updated_at = $ts else . end)
    | .routes |= map(if ((.managed_by // "") == ("forward:" + $fid)) then .enabled = ($next == "true") | .updated_at = $ts else . end)
    | .meta.updated_at = $ts
  '

  ps_log_success "转发链状态已切换： ${forward_id} => ${next}"
}

ps_forward_delete() {
  ps_print_header "删除转发链"

  local forward_id
  forward_id="$(ps_forward_pick_id)" || return 1

  printf "1) 仅删除转发链对象（保留入口/上游/规则）\n"
  printf "2) 删除转发链 + 自动创建的关联对象（入口/规则/上游）\n"
  printf "3) 取消\n"
  local mode
  mode="$(ps_prompt_required "请选择删除模式")"

  case "${mode}" in
    1)
      ps_manifest_update --arg fid "${forward_id}" --arg ts "$(ps_now_iso)" '.forwardings |= map(select(.forward_id != $fid)) | .meta.updated_at = $ts'
      ps_log_success "已删除转发链对象： ${forward_id}"
      ;;
    2)
      ps_manifest_update --arg fid "${forward_id}" --arg ts "$(ps_now_iso)" '
        .forwardings |= map(select(.forward_id != $fid))
        | .routes |= map(select((.managed_by // "") != ("forward:" + $fid)))
        | .inbounds |= map(select((.managed_by // "") != ("forward:" + $fid)))
        | .outbounds |= map(select((.managed_by // "") != ("forward:" + $fid)))
        | .meta.updated_at = $ts
      '
      ps_log_success "已删除转发链及关联对象： ${forward_id}"
      ;;
    3)
      ps_log_info "已取消"
      ;;
    *)
      ps_log_error "选择无效"
      return 1
      ;;
  esac
}
