#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_ROUTE_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_ROUTE_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"

ps_route_pick_name() {
  mapfile -t rows < <(jq -r '.routes | sort_by(.priority)[] | "\(.name)|\(.priority)|\(.outbound)|\(.enabled)"' "${PS_MANIFEST}")
  if [[ "${#rows[@]}" -eq 0 ]]; then
    ps_log_warn "未找到路由规则。"
    return 1
  fi

  local i=1 row
  printf "\n" >&2
  for row in "${rows[@]}"; do
    IFS='|' read -r name priority outbound enabled <<<"${row}"
    printf "%d) %s priority=%s outbound=%s 启用=%s\n" "${i}" "${name}" "${priority}" "${outbound}" "${enabled}" >&2
    i=$((i + 1))
  done

  local choice
  choice="$(ps_prompt_required "请选择规则编号")"
  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#rows[@]})); then
    ps_log_error "规则选择无效"
    return 1
  fi

  IFS='|' read -r name _ <<<"${rows[choice-1]}"
  printf "%s" "${name}"
}

ps_route_pick_outbound() {
  mapfile -t rows < <(jq -r '.outbounds[] | select(.enabled != false) | "\(.tag)|\(.type)"' "${PS_MANIFEST}")
  if [[ "${#rows[@]}" -eq 0 ]]; then
    ps_log_warn "没有可用上游出口。"
    return 1
  fi

  local i=1 row
  printf "\n" >&2
  for row in "${rows[@]}"; do
    IFS='|' read -r tag type <<<"${row}"
    printf "%d) %s (%s)\n" "${i}" "${tag}" "${type}" >&2
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

ps_route_name_exists() {
  local name="${1:-}"
  jq -e --arg n "${name}" '.routes | any(.name == $n)' "${PS_MANIFEST}" >/dev/null 2>&1
}

ps_route_list() {
  ps_print_header "路由规则"
  jq -r '
    if (.routes | length) == 0 then
      "未配置路由规则。"
    else
      (.routes | sort_by(.priority)[] |
        "- "
        + (.name // "-")
        + " | priority=" + ((.priority // 0)|tostring)
        + " | 出口=" + (.outbound // "direct")
        + " | 入站匹配=" + (((.inbound_tag // [])|join(",")) // "")
        + " | 域名后缀=" + (((.domain_suffix // [])|join(",")) // "")
        + " | 域名关键词=" + (((.domain_keyword // [])|join(",")) // "")
        + " | IP/CIDR=" + (((.ip_cidr // [])|join(",")) // "")
        + " | 网络=" + (((.network // [])|join(",")) // "")
        + " | 启用=" + ((.enabled // true)|tostring)
      )
    end
  ' "${PS_MANIFEST}"
}

ps_route_build_rule_json() {
  local name="${1}" priority="${2}" inbound_tags="${3}" domain_suffix="${4}" domain_keyword="${5}" ip_cidr="${6}" network="${7}" outbound="${8}"
  jq -n \
    --arg name "${name}" \
    --argjson priority "${priority}" \
    --argjson inbound_tag "$(ps_csv_to_json_array "${inbound_tags}")" \
    --argjson domain_suffix "$(ps_csv_to_json_array "${domain_suffix}")" \
    --argjson domain_keyword "$(ps_csv_to_json_array "${domain_keyword}")" \
    --argjson ip_cidr "$(ps_csv_to_json_array "${ip_cidr}")" \
    --argjson network "$(ps_csv_to_json_array "${network}")" \
    --arg outbound "${outbound}" \
    --arg created_at "$(ps_now_iso)" \
    '{
      name:$name,
      priority:$priority,
      inbound_tag:$inbound_tag,
      domain_suffix:$domain_suffix,
      domain_keyword:$domain_keyword,
      ip_cidr:$ip_cidr,
      network:$network,
      outbound:$outbound,
      enabled:true,
      created_at:$created_at,
      updated_at:$created_at
    }'
}

ps_route_create_rule() {
  ps_print_header "创建路由规则"
  printf "提示：通常只需要设置“入口匹配 + 上游出口”，其余条件可留空。\n"

  local name priority inbound_tags domain_suffix domain_keyword ip_cidr network outbound fallback
  name="$(ps_prompt_required "规则名称")"
  if ps_route_name_exists "${name}"; then
    ps_log_error "规则名称已存在：${name}"
    return 1
  fi

  priority="$(ps_prompt "优先级（越小越优先）" "100")"
  if ! [[ "${priority}" =~ ^[0-9]+$ ]]; then
    ps_log_error "优先级无效"
    return 1
  fi

  fallback="$(ps_prompt "是否创建兜底规则（true/false）" "false")"
  if [[ "${fallback}" == "true" ]]; then
    inbound_tags=""
    domain_suffix=""
    domain_keyword=""
    ip_cidr=""
    network=""
  else
    inbound_tags="$(ps_prompt "入口标签匹配（逗号分隔，可选）" "")"
    domain_suffix="$(ps_prompt "域名后缀匹配（逗号分隔，可选）" "")"
    domain_keyword="$(ps_prompt "域名关键词匹配（逗号分隔，可选）" "")"
    ip_cidr="$(ps_prompt "IP/CIDR 匹配（逗号分隔，可选）" "")"
    network="$(ps_prompt "网络匹配 tcp/udp（逗号分隔，可选）" "")"
  fi

  outbound="$(ps_route_pick_outbound)" || return 1

  local route_json
  route_json="$(ps_route_build_rule_json "${name}" "${priority}" "${inbound_tags}" "${domain_suffix}" "${domain_keyword}" "${ip_cidr}" "${network}" "${outbound}")"

  ps_manifest_update --argjson route "${route_json}" --arg ts "$(ps_now_iso)" '.routes += [$route] | .meta.updated_at = $ts'

  ps_log_success "路由规则已创建： ${name}"
  printf "摘要：名称=%s | priority=%s | 出口=%s | 启用=true\n" "${name}" "${priority}" "${outbound}"
  printf "下一步建议：\n"
  printf -- "- 可前往“路由与规则”测试匹配\n"
  printf -- "- 可前往“运行状态与诊断”查看应用状态\n"
}

ps_route_edit_rule() {
  ps_print_header "编辑路由规则"
  local name
  name="$(ps_route_pick_name)" || return 1

  local priority enabled inbound_tags domain_suffix domain_keyword ip_cidr network outbound_choice outbound
  priority="$(ps_prompt "新优先级（留空保持）" "")"
  enabled="$(ps_prompt "启用状态 true/false（留空保持）" "")"
  inbound_tags="$(ps_prompt "入口标签匹配（逗号分隔，留空保持）" "")"
  domain_suffix="$(ps_prompt "域名后缀匹配（逗号分隔，留空保持）" "")"
  domain_keyword="$(ps_prompt "域名关键词匹配（逗号分隔，留空保持）" "")"
  ip_cidr="$(ps_prompt "IP/CIDR 匹配（逗号分隔，留空保持）" "")"
  network="$(ps_prompt "网络匹配（逗号分隔，留空保持）" "")"

  outbound_choice="$(ps_prompt "是否变更上游出口（true/false）" "false")"
  outbound=""
  if [[ "${outbound_choice}" == "true" ]]; then
    outbound="$(ps_route_pick_outbound)" || return 1
  fi

  if [[ -n "${priority}" ]] && ! [[ "${priority}" =~ ^[0-9]+$ ]]; then
    ps_log_error "优先级无效"
    return 1
  fi

  local jq_filter='.routes |= map(if .name == $name then . else . end)'
  [[ -n "${priority}" ]] && jq_filter+=' | .routes |= map(if .name == $name then .priority = ($priority|tonumber) else . end)'
  [[ -n "${enabled}" ]] && jq_filter+=' | .routes |= map(if .name == $name then .enabled = ($enabled == "true") else . end)'
  [[ -n "${inbound_tags}" ]] && jq_filter+=' | .routes |= map(if .name == $name then .inbound_tag = $inbound_tag else . end)'
  [[ -n "${domain_suffix}" ]] && jq_filter+=' | .routes |= map(if .name == $name then .domain_suffix = $domain_suffix else . end)'
  [[ -n "${domain_keyword}" ]] && jq_filter+=' | .routes |= map(if .name == $name then .domain_keyword = $domain_keyword else . end)'
  [[ -n "${ip_cidr}" ]] && jq_filter+=' | .routes |= map(if .name == $name then .ip_cidr = $ip_cidr else . end)'
  [[ -n "${network}" ]] && jq_filter+=' | .routes |= map(if .name == $name then .network = $network else . end)'
  [[ -n "${outbound}" ]] && jq_filter+=' | .routes |= map(if .name == $name then .outbound = $outbound else . end)'
  jq_filter+=' | .routes |= map(if .name == $name then .updated_at = $ts else . end) | .meta.updated_at = $ts'

  ps_manifest_update \
    --arg name "${name}" \
    --arg priority "${priority}" \
    --arg enabled "${enabled}" \
    --argjson inbound_tag "$(ps_csv_to_json_array "${inbound_tags}")" \
    --argjson domain_suffix "$(ps_csv_to_json_array "${domain_suffix}")" \
    --argjson domain_keyword "$(ps_csv_to_json_array "${domain_keyword}")" \
    --argjson ip_cidr "$(ps_csv_to_json_array "${ip_cidr}")" \
    --argjson network "$(ps_csv_to_json_array "${network}")" \
    --arg outbound "${outbound}" \
    --arg ts "$(ps_now_iso)" \
    "${jq_filter}"

  ps_log_success "路由规则已更新： ${name}"
}

ps_route_toggle_rule() {
  ps_print_header "启用/禁用路由规则"
  local name
  name="$(ps_route_pick_name)" || return 1

  local current new_val
  current="$(jq -r --arg n "${name}" '.routes[] | select(.name==$n) | (.enabled // true)' "${PS_MANIFEST}")"
  if [[ "${current}" == "true" ]]; then
    new_val="false"
  else
    new_val="true"
  fi

  ps_manifest_update --arg n "${name}" --arg nv "${new_val}" --arg ts "$(ps_now_iso)" '.routes |= map(if .name==$n then .enabled = ($nv == "true") | .updated_at = $ts else . end) | .meta.updated_at = $ts'
  ps_log_success "路由规则状态已切换： ${name} => ${new_val}"
}

ps_route_swap_with_neighbor() {
  local name="${1}" direction="${2}"

  local neighbor
  if [[ "${direction}" == "up" ]]; then
    neighbor="$(jq -r --arg n "${name}" '
      (.routes|sort_by(.priority)) as $r
      | ($r|map(.name)|index($n)) as $idx
      | if $idx == null or $idx == 0 then "" else $r[$idx-1].name end
    ' "${PS_MANIFEST}")"
  else
    neighbor="$(jq -r --arg n "${name}" '
      (.routes|sort_by(.priority)) as $r
      | ($r|map(.name)|index($n)) as $idx
      | if $idx == null or $idx >= (($r|length)-1) then "" else $r[$idx+1].name end
    ' "${PS_MANIFEST}")"
  fi

  if [[ -z "${neighbor}" ]]; then
    ps_log_warn "无法继续移动：已在边界位置。"
    return 1
  fi

  local p1 p2
  p1="$(jq -r --arg n "${name}" '.routes[] | select(.name==$n) | .priority' "${PS_MANIFEST}")"
  p2="$(jq -r --arg n "${neighbor}" '.routes[] | select(.name==$n) | .priority' "${PS_MANIFEST}")"

  ps_manifest_update --arg a "${name}" --arg b "${neighbor}" --argjson p1 "${p1}" --argjson p2 "${p2}" --arg ts "$(ps_now_iso)" '
    .routes |= map(
      if .name == $a then .priority = $p2 | .updated_at = $ts
      elif .name == $b then .priority = $p1 | .updated_at = $ts
      else . end
    )
    | .meta.updated_at = $ts
  '

  ps_log_success "已移动规则： ${name} (${direction})"
}

ps_route_move_up() {
  ps_print_header "路由规则上移"
  local name
  name="$(ps_route_pick_name)" || return 1
  ps_route_swap_with_neighbor "${name}" "up"
}

ps_route_move_down() {
  ps_print_header "路由规则下移"
  local name
  name="$(ps_route_pick_name)" || return 1
  ps_route_swap_with_neighbor "${name}" "down"
}

ps_route_reorder_priority() {
  ps_print_header "调整路由优先级（手动）"
  local name
  name="$(ps_route_pick_name)" || return 1

  local priority
  priority="$(ps_prompt_required "新的优先级")"
  if ! [[ "${priority}" =~ ^[0-9]+$ ]]; then
    ps_log_error "优先级无效"
    return 1
  fi

  ps_manifest_update --arg name "${name}" --argjson priority "${priority}" --arg ts "$(ps_now_iso)" '.routes |= map(if .name == $name then .priority = $priority | .updated_at = $ts else . end) | .meta.updated_at = $ts'
  ps_log_success "路由优先级已更新： ${name} => ${priority}"
}

ps_route_delete_rule() {
  ps_print_header "删除路由规则"
  local name
  name="$(ps_route_pick_name)" || return 1

  local fwd_refs
  fwd_refs="$(jq -r --arg n "${name}" '[.forwardings[]? | select(.route_name == $n)] | length' "${PS_MANIFEST}")"

  if [[ "${fwd_refs}" -gt 0 ]]; then
    ps_log_warn "检测到该规则被 ${fwd_refs} 条转发链引用。"
    printf "1) 取消删除\n"
    printf "2) 解绑转发链后删除\n"
    local action
    action="$(ps_prompt_required "请选择")"
    case "${action}" in
      1) ps_log_info "已取消"; return 0 ;;
      2)
        ps_manifest_update --arg n "${name}" --arg ts "$(ps_now_iso)" '.forwardings |= map(if .route_name == $n then .route_name = "" | .updated_at = $ts else . end) | .meta.updated_at = $ts'
        ;;
      *) ps_log_error "选择无效"; return 1 ;;
    esac
  else
    if ! ps_confirm "确认删除路由规则 ${name}？" "N"; then
      ps_log_info "已取消"
      return 0
    fi
  fi

  ps_manifest_update --arg n "${name}" --arg ts "$(ps_now_iso)" '.routes |= map(select(.name != $n)) | .meta.updated_at = $ts'
  ps_log_success "路由规则已删除： ${name}"
}

ps_route_domain_match() {
  local domain="${1}"
  local suffix_json="${2}"
  local keyword_json="${3}"

  if [[ "$(jq 'length' <<<"${suffix_json}")" -gt 0 ]]; then
    if ! jq -e --arg d "${domain}" 'any(.[]; $d | endswith(.))' <<<"${suffix_json}" >/dev/null; then
      return 1
    fi
  fi

  if [[ "$(jq 'length' <<<"${keyword_json}")" -gt 0 ]]; then
    if ! jq -e --arg d "${domain}" 'any(.[]; $d | contains(.))' <<<"${keyword_json}" >/dev/null; then
      return 1
    fi
  fi

  return 0
}

ps_route_ip_match() {
  local ip="${1}"
  local cidr_json="${2}"

  if [[ "$(jq 'length' <<<"${cidr_json}")" -eq 0 ]]; then
    return 0
  fi

  local cidr
  while IFS= read -r cidr; do
    local prefix="${cidr%/*}"
    if [[ -n "${prefix}" && "${ip}" == ${prefix}* ]]; then
      return 0
    fi
  done < <(jq -r '.[]' <<<"${cidr_json}")

  return 1
}

ps_route_test_match() {
  ps_print_header "测试路由匹配"

  local inbound_tag domain ip network
  inbound_tag="$(ps_prompt "入口标签" "")"
  domain="$(ps_prompt "域名" "")"
  ip="$(ps_prompt "IP" "")"
  network="$(ps_prompt "网络（tcp/udp）" "tcp")"

  mapfile -t routes < <(jq -c '.routes | sort_by(.priority)[] | select(.enabled != false)' "${PS_MANIFEST}")
  if [[ "${#routes[@]}" -eq 0 ]]; then
    ps_log_warn "没有可测试的路由规则"
    return 1
  fi

  local route matched=0
  for route in "${routes[@]}"; do
    local name outbound
    name="$(jq -r '.name' <<<"${route}")"
    outbound="$(jq -r '.outbound' <<<"${route}")"

    local inbound_json suffix_json keyword_json cidr_json network_json
    inbound_json="$(jq -c '.inbound_tag // []' <<<"${route}")"
    suffix_json="$(jq -c '.domain_suffix // []' <<<"${route}")"
    keyword_json="$(jq -c '.domain_keyword // []' <<<"${route}")"
    cidr_json="$(jq -c '.ip_cidr // []' <<<"${route}")"
    network_json="$(jq -c '.network // []' <<<"${route}")"

    if [[ "$(jq 'length' <<<"${inbound_json}")" -gt 0 ]]; then
      if ! jq -e --arg t "${inbound_tag}" 'index($t) != null' <<<"${inbound_json}" >/dev/null; then
        continue
      fi
    fi

    if ! ps_route_domain_match "${domain}" "${suffix_json}" "${keyword_json}"; then
      continue
    fi

    if ! ps_route_ip_match "${ip}" "${cidr_json}"; then
      continue
    fi

    if [[ "$(jq 'length' <<<"${network_json}")" -gt 0 ]]; then
      local nlow
      nlow="$(printf '%s' "${network}" | tr '[:upper:]' '[:lower:]')"
      if ! jq -e --arg n "${nlow}" 'any(.[]; (.|ascii_downcase) == $n)' <<<"${network_json}" >/dev/null; then
        continue
      fi
    fi

    printf "匹配到规则： %s => 出口=%s\n" "${name}" "${outbound}"
    matched=1
    break
  done

  if [[ "${matched}" -eq 0 ]]; then
    printf "未匹配到规则，将使用默认行为。\n"
  fi
}

# 兼容旧调用
ps_route_create_forwarding() {
  if declare -F ps_forward_create >/dev/null 2>&1; then
    ps_forward_create
    return $?
  fi
  ps_log_error "转发模块未加载，请先 source lib/forward.sh。"
  return 1
}
