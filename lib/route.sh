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
    ps_log_warn "未找到路由。"
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
  choice="$(ps_prompt_required "请选择路由编号")"
  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#rows[@]})); then
    ps_log_error "路由选择无效"
    return 1
  fi

  IFS='|' read -r name _ <<<"${rows[choice-1]}"
  printf "%s" "${name}"
}

ps_route_pick_outbound() {
  mapfile -t rows < <(jq -r '.outbounds[] | select(.enabled != false) | "\(.tag)|\(.type)"' "${PS_MANIFEST}")
  if [[ "${#rows[@]}" -eq 0 ]]; then
    ps_log_warn "没有可用出站。"
    return 1
  fi

  local i=1 row
  for row in "${rows[@]}"; do
    IFS='|' read -r tag type <<<"${row}"
    printf "%d) %s (%s)\n" "${i}" "${tag}" "${type}" >&2
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

ps_route_list() {
  ps_print_header "路由规则"
  jq -r '
    if (.routes | length) == 0 then
      "未配置路由。"
    else
      (.routes | sort_by(.priority)[] |
        "- \(.name) priority=\(.priority) outbound=\(.outbound) inbound_tags=\((.inbound_tag // [])|join(",")) domain_suffix=\((.domain_suffix // [])|join(",")) domain_keyword=\((.domain_keyword // [])|join(",")) ip_cidr=\((.ip_cidr // [])|join(",")) network=\((.network // [])|join(",")) 启用=\(.enabled)")
    end
  ' "${PS_MANIFEST}"
}

ps_route_create_rule() {
  ps_print_header "创建路由规则"

  local name priority inbound_tags domain_suffix domain_keyword ip_cidr network outbound
  name="$(ps_prompt_required "规则名称")"
  priority="$(ps_prompt "优先级（越小越优先）" "100")"
  inbound_tags="$(ps_prompt "入站标签（逗号分隔，可选）" "")"
  domain_suffix="$(ps_prompt "域名后缀列表（逗号分隔，可选）" "")"
  domain_keyword="$(ps_prompt "域名关键词列表（逗号分隔，可选）" "")"
  ip_cidr="$(ps_prompt "IP/CIDR 列表（逗号分隔，可选）" "")"
  network="$(ps_prompt "网络列表 TCP/UDP（逗号分隔，可选）" "")"
  outbound="$(ps_route_pick_outbound)" || return 1

  if ! [[ "${priority}" =~ ^[0-9]+$ ]]; then
    ps_log_error "优先级无效"
    return 1
  fi

  local route_json
  route_json="$(jq -n \
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
    }')"

  ps_manifest_update --argjson route "${route_json}" --arg ts "$(ps_now_iso)" '.routes += [$route] | .meta.updated_at = $ts'
  ps_log_success "路由已创建： ${name}"
}

ps_route_create_forwarding() {
  if declare -F ps_forward_create >/dev/null 2>&1; then
    ps_forward_create
    return $?
  fi

  ps_log_error "转发模块未加载，请先 source lib/forward.sh。"
  return 1
}

ps_route_reorder_priority() {
  ps_print_header "调整路由优先级"
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
    # TODO: Replace with strict CIDR match implementation.
    if [[ -n "${prefix}" && "${ip}" == ${prefix}* ]]; then
      return 0
    fi
  done < <(jq -r '.[]' <<<"${cidr_json}")

  return 1
}

ps_route_test_match() {
  ps_print_header "测试路由匹配"

  local inbound_tag domain ip network
  inbound_tag="$(ps_prompt "入站标签" "")"
  domain="$(ps_prompt "域名" "")"
  ip="$(ps_prompt "IP" "")"
  network="$(ps_prompt "网络（tcp/udp）" "tcp")"

  mapfile -t routes < <(jq -c '.routes | sort_by(.priority)[] | select(.enabled != false)' "${PS_MANIFEST}")
  if [[ "${#routes[@]}" -eq 0 ]]; then
    ps_log_warn "没有可测试的路由"
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
      if ! jq -e --arg n "${network,,}" 'any(.[]; ascii_downcase == $n)' <<<"${network_json}" >/dev/null; then
        continue
      fi
    fi

    printf "匹配到路由： %s => outbound=%s\n" "${name}" "${outbound}"
    matched=1
    break
  done

  if [[ "${matched}" -eq 0 ]]; then
    printf "未匹配到规则，将使用默认行为。\n"
  fi
}
