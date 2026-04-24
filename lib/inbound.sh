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
  mapfile -t rows < <(jq -r '.inbounds[] | "\(.tag)|\(.type)|\(.listen):\(.port)|\(.enabled)|\(.public // false)"' "${PS_MANIFEST}")
  if [[ "${#rows[@]}" -eq 0 ]]; then
    ps_log_warn "未找到入口。"
    return 1
  fi

  local i=1 row
  printf "\n" >&2
  for row in "${rows[@]}"; do
    IFS='|' read -r tag type endpoint enabled public <<<"${row}"
    printf "%d) %s type=%s endpoint=%s 启用=%s 公网=%s\n" "${i}" "${tag}" "${type}" "${endpoint}" "${enabled}" "${public}" >&2
    i=$((i + 1))
  done

  local choice
  choice="$(ps_prompt_required "请选择入口编号")"
  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#rows[@]})); then
    ps_log_error "入口选择无效"
    return 1
  fi

  IFS='|' read -r tag _ <<<"${rows[choice-1]}"
  printf "%s" "${tag}"
}

ps_inbound_list() {
  ps_print_header "入口列表"
  jq -r '
    if (.inbounds | length) == 0 then
      "未配置入口。"
    else
      (.inbounds[] |
        "- " + (.tag // "-")
        + " | 类型=" + (.type // "-")
        + " | 监听=" + ((.listen // "-") + ":" + ((.port // "-")|tostring))
        + " | 公网入口=" + ((.public // false)|tostring)
        + " | 绑定服务=" + (.stack_id // "-")
        + " | 启用=" + ((.enabled // true)|tostring)
      )
    end
  ' "${PS_MANIFEST}"
}

ps_inbound_list_local_only() {
  ps_print_header "本地代理入口"
  jq -r '
    if ([.inbounds[]? | select(.public != true)] | length) == 0 then
      "未配置本地代理入口。"
    else
      (.inbounds[]? | select(.public != true) |
        "- " + .tag + " | 类型=" + (.type // "-") + " | 监听=" + (.listen // "-") + ":" + ((.port // "-")|tostring) + " | 启用=" + ((.enabled // true)|tostring)
      )
    end
  ' "${PS_MANIFEST}"
}

ps_inbound_create_public() {
  ps_print_header "创建公网服务入口"
  local stack_id

  mapfile -t stacks < <(jq -r '.stacks[] | "\(.stack_id)|\(.name)|\(.protocol)|\(.port)"' "${PS_MANIFEST}")
  if [[ "${#stacks[@]}" -eq 0 ]]; then
    ps_log_warn "未找到服务，请先创建服务。"
    return 1
  fi

  local i=1 row
  for row in "${stacks[@]}"; do
    IFS='|' read -r sid name protocol port <<<"${row}"
    printf "%d) %s (%s:%s) [%s]\n" "${i}" "${name}" "${protocol}" "${port}" "${sid}"
    i=$((i + 1))
  done

  local selected
  selected="$(ps_prompt_required "请选择服务编号")"
  if ! [[ "${selected}" =~ ^[0-9]+$ ]] || ((selected < 1 || selected > ${#stacks[@]})); then
    ps_log_error "选择无效"
    return 1
  fi

  IFS='|' read -r stack_id _ protocol stack_port <<<"${stacks[selected-1]}"
  local tag listen port
  tag="$(ps_prompt "入口标签" "pub-${stack_id}")"
  listen="$(ps_prompt "监听地址" "0.0.0.0")"
  port="$(ps_prompt_for_port "监听端口（建议 ${stack_port}, 回车随机）")"

  if ! ps_validate_port "${port}"; then
    ps_log_error "端口无效"
    return 1
  fi

  if ps_manifest_array_has '.inbounds' 'tag' "${tag}"; then
    ps_log_error "入口标签已存在: ${tag}"
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
  ps_log_success "公网服务入口已创建： ${tag}"
}

ps_inbound_create_local() {
  ps_print_header "创建本地代理入口"
  printf "1) SOCKS5\n2) HTTP\n3) Mixed\n"
  local type_choice inbound_type
  type_choice="$(ps_prompt_required "入口类型编号")"
  case "${type_choice}" in
    1) inbound_type="socks" ;;
    2) inbound_type="http" ;;
    3) inbound_type="mixed" ;;
    *) ps_log_error "类型无效"; return 1 ;;
  esac

  local default_port="1080"
  [[ "${inbound_type}" == "http" ]] && default_port="8080"

  local tag listen port username password udp
  tag="$(ps_prompt "入口标签" "local-${inbound_type}-$(ps_generate_id in | awk -F'-' '{print $NF}')")"
  listen="$(ps_prompt "本地监听地址" "127.0.0.1")"
  port="$(ps_prompt_for_port "监听端口（建议 ${default_port}, 回车随机）")"
  username="$(ps_prompt "认证用户名（可选）" "")"
  password="$(ps_prompt "认证密码（可选）" "")"
  udp="$(ps_prompt "启用 UDP（true/false）" "true")"

  if ! ps_validate_port "${port}"; then
    ps_log_error "端口无效"
    return 1
  fi

  if ps_manifest_array_has '.inbounds' 'tag' "${tag}"; then
    ps_log_error "入口标签已存在: ${tag}"
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

  ps_log_success "本地代理入口已创建： ${tag}"
  printf "摘要：标签=%s | 类型=%s | 监听=%s:%s | 启用=true\n" "${tag}" "${inbound_type}" "${listen}" "${port}"
  printf "下一步建议：\n"
  printf -- "- 可前往“本地代理与转发”创建转发链并绑定此入口\n"
  printf -- "- 可前往“路由与规则”添加按入口标签匹配规则\n"
}

ps_inbound_edit() {
  ps_print_header "编辑入口"
  local tag
  tag="$(ps_inbound_pick_tag)" || return 1

  local listen port udp username password enabled
  listen="$(ps_prompt "新监听地址（留空保持）" "")"
  port="$(ps_prompt "新端口（留空保持）" "")"
  udp="$(ps_prompt "UDP true/false（留空保持）" "")"
  username="$(ps_prompt "认证用户名（留空保持）" "")"
  password="$(ps_prompt "认证密码（留空保持）" "")"
  enabled="$(ps_prompt "启用状态 true/false（留空保持）" "")"

  if [[ -n "${port}" ]] && ! ps_validate_port "${port}"; then
    ps_log_error "端口无效"
    return 1
  fi
  if [[ -n "${port}" ]]; then
    local current_port
    current_port="$(jq -r --arg tag "${tag}" '.inbounds[] | select(.tag == $tag) | .port // 0' "${PS_MANIFEST}")"
    if [[ "${port}" != "${current_port}" ]] && ps_port_is_in_use "${port}"; then
      ps_log_error "端口冲突：${port} 已被占用或已登记。"
      return 1
    fi
  fi

  local jq_filter='.inbounds |= map(if .tag == $tag then . else . end)'
  [[ -n "${listen}" ]] && jq_filter+=' | .inbounds |= map(if .tag == $tag then .listen = $listen else . end)'
  [[ -n "${port}" ]] && jq_filter+=' | .inbounds |= map(if .tag == $tag then .port = ($port|tonumber) else . end)'
  [[ -n "${udp}" ]] && jq_filter+=' | .inbounds |= map(if .tag == $tag then .udp = ($udp == "true") else . end)'
  [[ -n "${username}" ]] && jq_filter+=' | .inbounds |= map(if .tag == $tag then .auth.username = $username else . end)'
  [[ -n "${password}" ]] && jq_filter+=' | .inbounds |= map(if .tag == $tag then .auth.password = $password else . end)'
  [[ -n "${enabled}" ]] && jq_filter+=' | .inbounds |= map(if .tag == $tag then .enabled = ($enabled == "true") else . end)'
  jq_filter+=' | .inbounds |= map(if .tag == $tag then .updated_at = $ts else . end) | .meta.updated_at = $ts'

  ps_manifest_update \
    --arg tag "${tag}" \
    --arg listen "${listen}" \
    --arg port "${port}" \
    --arg udp "${udp}" \
    --arg username "${username}" \
    --arg password "${password}" \
    --arg enabled "${enabled}" \
    --arg ts "$(ps_now_iso)" \
    "${jq_filter}"

  ps_log_success "入口已更新： ${tag}"
}

ps_inbound_delete() {
  ps_print_header "删除入口"
  local tag
  tag="$(ps_inbound_pick_tag)" || return 1

  local route_refs fwd_refs
  route_refs="$(jq -r --arg tag "${tag}" '[.routes[]? | select((.inbound_tag // []) | index($tag) != null)] | length' "${PS_MANIFEST}")"
  fwd_refs="$(jq -r --arg tag "${tag}" '[.forwardings[]? | select(.inbound_tag == $tag)] | length' "${PS_MANIFEST}")"

  if [[ "${route_refs}" -gt 0 || "${fwd_refs}" -gt 0 ]]; then
    ps_log_warn "该入口存在引用：路由=${route_refs}，转发链=${fwd_refs}。"
    printf "1) 取消\n"
    printf "2) 安全解绑后删除（路由去掉入口匹配，并删除关联转发链）\n"
    local action
    action="$(ps_prompt_required "请选择")"
    case "${action}" in
      1) ps_log_info "已取消"; return 0 ;;
      2)
        ps_manifest_update --arg tag "${tag}" --arg ts "$(ps_now_iso)" '
          .routes |= map(if ((.inbound_tag // []) | index($tag)) != null then .inbound_tag = ((.inbound_tag // []) - [$tag]) | .updated_at = $ts else . end)
          | .forwardings |= map(select(.inbound_tag != $tag))
          | .meta.updated_at = $ts
        '
        ;;
      *) ps_log_error "选择无效"; return 1 ;;
    esac
  else
    if ! ps_confirm "删除入口 ${tag}？" "N"; then
      ps_log_info "已取消"
      return 0
    fi
  fi

  ps_manifest_update --arg tag "${tag}" --arg ts "$(ps_now_iso)" '.inbounds |= map(select(.tag != $tag)) | .meta.updated_at = $ts'
  ps_log_success "入口已删除： ${tag}"
}

ps_inbound_bind_stack() {
  ps_print_header "绑定入口到服务"
  local tag stack_id
  tag="$(ps_inbound_pick_tag)" || return 1

  mapfile -t stacks < <(jq -r '.stacks[] | "\(.stack_id)|\(.name)|\(.engine)"' "${PS_MANIFEST}")
  if [[ "${#stacks[@]}" -eq 0 ]]; then
    ps_log_warn "没有可用服务"
    return 1
  fi

  local i=1 row
  for row in "${stacks[@]}"; do
    IFS='|' read -r sid name engine <<<"${row}"
    printf "%d) %s [%s] (%s)\n" "${i}" "${name}" "${sid}" "${engine}"
    i=$((i + 1))
  done

  local choice
  choice="$(ps_prompt_required "请选择服务编号")"
  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#stacks[@]})); then
    ps_log_error "选择无效"
    return 1
  fi

  IFS='|' read -r stack_id _ <<<"${stacks[choice-1]}"

  ps_manifest_update --arg tag "${tag}" --arg stack_id "${stack_id}" --arg ts "$(ps_now_iso)" '.inbounds |= map(if .tag == $tag then .stack_id = $stack_id | .updated_at = $ts else . end) | .meta.updated_at = $ts'
  ps_log_success "入口 ${tag} 已绑定到服务 ${stack_id}"
}
