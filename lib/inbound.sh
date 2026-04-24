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
    ps_log_warn "未找到入站。"
    return 1
  fi

  local i=1 row
  printf "\n"
  for row in "${rows[@]}"; do
    IFS='|' read -r tag type endpoint enabled <<<"${row}"
    printf "%d) %s type=%s endpoint=%s 启用=%s\n" "${i}" "${tag}" "${type}" "${endpoint}" "${enabled}"
    i=$((i + 1))
  done

  local choice
  choice="$(ps_prompt_required "请选择入站编号")"
  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#rows[@]})); then
    ps_log_error "入站选择无效"
    return 1
  fi

  IFS='|' read -r tag _ <<<"${rows[choice-1]}"
  printf "%s" "${tag}"
}

ps_inbound_list() {
  ps_print_header "入站列表"
  jq -r '
    if (.inbounds | length) == 0 then
      "未配置入站。"
    else
      (.inbounds[] |
        "- \(.tag) type=\(.type) listen=\(.listen):\(.port) udp=\(.udp) stack=\(.stack_id // "-") 启用=\(.enabled)")
    end
  ' "${PS_MANIFEST}"
}

ps_inbound_create_public() {
  ps_print_header "创建公网入站"
  local stack_id

  mapfile -t stacks < <(jq -r '.stacks[] | "\(.stack_id)|\(.name)|\(.protocol)|\(.port)"' "${PS_MANIFEST}")
  if [[ "${#stacks[@]}" -eq 0 ]]; then
    ps_log_warn "未找到协议栈，请先创建。"
    return 1
  fi

  local i=1 row
  for row in "${stacks[@]}"; do
    IFS='|' read -r sid name protocol port <<<"${row}"
    printf "%d) %s (%s:%s) [%s]\n" "${i}" "${name}" "${protocol}" "${port}" "${sid}"
    i=$((i + 1))
  done

  local selected
  selected="$(ps_prompt_required "请选择协议栈编号")"
  if ! [[ "${selected}" =~ ^[0-9]+$ ]] || ((selected < 1 || selected > ${#stacks[@]})); then
    ps_log_error "选择无效"
    return 1
  fi

  IFS='|' read -r stack_id _ protocol stack_port <<<"${stacks[selected-1]}"
  local tag listen port
  tag="$(ps_prompt "入站标签" "pub-${stack_id}")"
  listen="$(ps_prompt "监听地址" "0.0.0.0")"
  port="$(ps_prompt_for_port "监听端口（建议 ${stack_port}, 回车随机）")"

  if ! ps_validate_port "${port}"; then
    ps_log_error "端口无效"
    return 1
  fi

  if ps_manifest_array_has '.inbounds' 'tag' "${tag}"; then
    ps_log_error "入站标签 already exists: ${tag}"
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
  ps_log_success "公网入站已创建： ${tag}"
}

ps_inbound_create_local() {
  ps_print_header "创建本地入站"
  printf "1) SOCKS5\n2) HTTP\n3) Mixed\n"
  local type_choice inbound_type
  type_choice="$(ps_prompt_required "入站类型编号")"
  case "${type_choice}" in
    1) inbound_type="socks" ;;
    2) inbound_type="http" ;;
    3) inbound_type="mixed" ;;
    *) ps_log_error "类型无效"; return 1 ;;
  esac

  local default_port="1080"
  [[ "${inbound_type}" == "http" ]] && default_port="8080"

  local tag listen port username password udp
  tag="$(ps_prompt "入站标签" "local-${inbound_type}-$(ps_generate_id in | awk -F'-' '{print $NF}')")"
  listen="$(ps_prompt "监听地址" "127.0.0.1")"
  port="$(ps_prompt_for_port "监听端口（建议 ${default_port}, 回车随机）")"
  username="$(ps_prompt "认证用户名（可选）" "")"
  password="$(ps_prompt "认证密码（可选）" "")"
  udp="$(ps_prompt "启用 UDP（true/false）" "true")"

  if ! ps_validate_port "${port}"; then
    ps_log_error "端口无效"
    return 1
  fi

  if ps_manifest_array_has '.inbounds' 'tag' "${tag}"; then
    ps_log_error "入站标签 already exists: ${tag}"
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
  ps_log_success "本地入站已创建： ${tag}"
}

ps_inbound_edit() {
  ps_print_header "编辑入站"
  local tag
  tag="$(ps_inbound_pick_tag)" || return 1

  local listen port udp username password
  listen="$(ps_prompt "新监听地址（留空保持）" "")"
  port="$(ps_prompt "新端口（留空保持）" "")"
  udp="$(ps_prompt "UDP true/false（留空保持）" "")"
  username="$(ps_prompt "认证用户名（留空保持）" "")"
  password="$(ps_prompt "认证密码（留空保持）" "")"

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

  ps_log_success "入站已更新： ${tag}"
}

ps_inbound_delete() {
  ps_print_header "删除入站"
  local tag
  tag="$(ps_inbound_pick_tag)" || return 1

  if ! ps_confirm "删除入站 ${tag}?" "N"; then
    ps_log_info "已取消"
    return 0
  fi

  ps_manifest_update --arg tag "${tag}" --arg ts "$(ps_now_iso)" '.inbounds |= map(select(.tag != $tag)) | .meta.updated_at = $ts'
  ps_log_success "入站已删除： ${tag}"
}

ps_inbound_bind_stack() {
  ps_print_header "绑定入站到协议栈"
  local tag stack_id
  tag="$(ps_inbound_pick_tag)" || return 1

  mapfile -t stacks < <(jq -r '.stacks[] | "\(.stack_id)|\(.name)|\(.engine)"' "${PS_MANIFEST}")
  if [[ "${#stacks[@]}" -eq 0 ]]; then
    ps_log_warn "没有可用协议栈"
    return 1
  fi

  local i=1 row
  for row in "${stacks[@]}"; do
    IFS='|' read -r sid name engine <<<"${row}"
    printf "%d) %s [%s] (%s)\n" "${i}" "${name}" "${sid}" "${engine}"
    i=$((i + 1))
  done

  local choice
  choice="$(ps_prompt_required "请选择协议栈编号")"
  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#stacks[@]})); then
    ps_log_error "选择无效"
    return 1
  fi

  IFS='|' read -r stack_id _ <<<"${stacks[choice-1]}"

  ps_manifest_update --arg tag "${tag}" --arg stack_id "${stack_id}" --arg ts "$(ps_now_iso)" '.inbounds |= map(if .tag == $tag then .stack_id = $stack_id | .updated_at = $ts else . end) | .meta.updated_at = $ts'
  ps_log_success "入站 ${tag} 已绑定到协议栈 ${stack_id}"
}
