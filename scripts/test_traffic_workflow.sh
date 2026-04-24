#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

STATE_DIR="${ROOT_DIR}/state"
BACKUP_DIR="$(mktemp -d)"
RESTORE_NEEDED=0

if [[ -d "${STATE_DIR}" ]]; then
  cp -a "${STATE_DIR}" "${BACKUP_DIR}/state.bak"
  RESTORE_NEEDED=1
fi

cleanup() {
  rm -rf "${STATE_DIR}"
  if [[ "${RESTORE_NEEDED}" -eq 1 && -d "${BACKUP_DIR}/state.bak" ]]; then
    cp -a "${BACKUP_DIR}/state.bak" "${STATE_DIR}"
  fi
  rm -rf "${BACKUP_DIR}"
}
trap cleanup EXIT

# shellcheck source=lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=lib/logger.sh
source "${ROOT_DIR}/lib/logger.sh"
# shellcheck source=lib/inbound.sh
source "${ROOT_DIR}/lib/inbound.sh"
# shellcheck source=lib/outbound.sh
source "${ROOT_DIR}/lib/outbound.sh"
# shellcheck source=lib/route.sh
source "${ROOT_DIR}/lib/route.sh"
# shellcheck source=lib/forward.sh
source "${ROOT_DIR}/lib/forward.sh"

ps_prepare_runtime_dirs
ps_logger_init
ps_init_manifest

assert_eq() {
  local expected="${1}"
  local actual="${2}"
  local message="${3}"
  if [[ "${expected}" != "${actual}" ]]; then
    printf "[FAIL] %s: expected=%s actual=%s\n" "${message}" "${expected}" "${actual}" >&2
    exit 1
  fi
}

assert_true() {
  local cmd="${1}"
  local message="${2}"
  if ! eval "${cmd}"; then
    printf "[FAIL] %s\n" "${message}" >&2
    exit 1
  fi
}

reset_manifest_fixture() {
  rm -f "${PS_MANIFEST}"
  ps_init_manifest
}

printf "[TEST] CIDR 严格匹配...\n"
assert_true "ps_route_ipv4_in_cidr 10.0.1.5 10.0.0.0/16" "10.0.1.5 应命中 10.0.0.0/16"
assert_true "! ps_route_ipv4_in_cidr 10.0.1.5 10.0.0.0/24" "10.0.1.5 不应命中 10.0.0.0/24"
assert_true "ps_route_ipv4_in_cidr 192.168.1.10 192.168.1.10" "单 IP 规则应等价 /32"

printf "[TEST] 路由删除引用解绑...\n"
reset_manifest_fixture

ps_manifest_update --argjson inbound '{"tag":"local-a","type":"socks","listen":"127.0.0.1","port":18080,"auth":{},"udp":true,"stack_id":"","public":false,"enabled":true,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}' --arg ts "$(ps_now_iso)" '.inbounds += [$inbound] | .meta.updated_at = $ts'
ps_manifest_update --argjson outbound '{"tag":"up-a","type":"socks5","server":"1.1.1.1","port":1080,"auth":{"username":"","password":""},"network":"tcp","enabled":true,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}' --arg ts "$(ps_now_iso)" '.outbounds += [$outbound] | .meta.updated_at = $ts'
ps_manifest_update --argjson route '{"name":"route-a","priority":50,"enabled":true,"inbound_tag":["local-a"],"domain_suffix":[],"domain_keyword":[],"ip_cidr":[],"network":[],"outbound":"up-a","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}' --arg ts "$(ps_now_iso)" '.routes += [$route] | .meta.updated_at = $ts'
ps_manifest_update --argjson fwd '{"forward_id":"fwd-a","name":"fwd-a","inbound_tag":"local-a","listen":"127.0.0.1","listen_port":18080,"outbound_tag":"up-a","target_host":"1.1.1.1","target_port":1080,"network":["tcp"],"route_name":"route-a","enabled":true,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}' --arg ts "$(ps_now_iso)" '.forwardings += [$fwd] | .meta.updated_at = $ts'

ps_route_delete_rule <<< $'1\n2\n'

route_a_count="$(jq -r '[.routes[]? | select(.name=="route-a")] | length' "${PS_MANIFEST}")"
assert_eq "0" "${route_a_count}" "route-a 应已删除"
route_name_after="$(jq -r '.forwardings[]? | select(.forward_id=="fwd-a") | .route_name // ""' "${PS_MANIFEST}")"
assert_eq "" "${route_name_after}" "fwd-a.route_name 应已解绑为空"

printf "[TEST] 删除入口安全解绑 + 关联清理...\n"
reset_manifest_fixture

ps_manifest_update --argjson inbound '{"tag":"local-x","type":"socks","listen":"127.0.0.1","port":19090,"auth":{},"udp":true,"stack_id":"","public":false,"enabled":true,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}' --arg ts "$(ps_now_iso)" '.inbounds += [$inbound] | .meta.updated_at = $ts'
ps_manifest_update --argjson outbound '{"tag":"shared-up","type":"http","server":"2.2.2.2","port":8080,"auth":{"username":"","password":""},"network":"tcp","enabled":true,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}' --arg ts "$(ps_now_iso)" '.outbounds += [$outbound] | .meta.updated_at = $ts'
ps_manifest_update --argjson route '{"name":"fwd-route-x","priority":60,"enabled":true,"inbound_tag":["local-x"],"domain_suffix":[],"domain_keyword":[],"ip_cidr":[],"network":["tcp"],"outbound":"shared-up","managed_by":"forward:fwd-x","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}' --arg ts "$(ps_now_iso)" '.routes += [$route] | .meta.updated_at = $ts'
ps_manifest_update --argjson route '{"name":"keep-route","priority":61,"enabled":true,"inbound_tag":["local-x"],"domain_suffix":[],"domain_keyword":[],"ip_cidr":[],"network":[],"outbound":"direct","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}' --arg ts "$(ps_now_iso)" '.routes += [$route] | .meta.updated_at = $ts'
ps_manifest_update --argjson fwd '{"forward_id":"fwd-x","name":"fwd-x","inbound_tag":"local-x","listen":"127.0.0.1","listen_port":19090,"outbound_tag":"shared-up","target_host":"2.2.2.2","target_port":8080,"network":["tcp"],"route_name":"fwd-route-x","enabled":true,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}' --arg ts "$(ps_now_iso)" '.forwardings += [$fwd] | .meta.updated_at = $ts'

# 入口编号=1, 动作=2(安全解绑), 删除孤儿上游=Y
ps_inbound_delete <<< $'1\n2\ny\n'

local_x_count="$(jq -r '[.inbounds[]? | select(.tag=="local-x")] | length' "${PS_MANIFEST}")"
assert_eq "0" "${local_x_count}" "local-x 应已删除"
fwd_x_count="$(jq -r '[.forwardings[]? | select(.forward_id=="fwd-x")] | length' "${PS_MANIFEST}")"
assert_eq "0" "${fwd_x_count}" "fwd-x 应已删除"
route_fwd_x_count="$(jq -r '[.routes[]? | select(.name=="fwd-route-x")] | length' "${PS_MANIFEST}")"
assert_eq "0" "${route_fwd_x_count}" "fwd-route-x 应已删除"
keep_route_inbound_count="$(jq -r '[.routes[]? | select(.name=="keep-route") | (.inbound_tag[]?)] | length' "${PS_MANIFEST}")"
assert_eq "0" "${keep_route_inbound_count}" "keep-route 应移除 local-x 匹配"
shared_up_count="$(jq -r '[.outbounds[]? | select(.tag=="shared-up")] | length' "${PS_MANIFEST}")"
assert_eq "0" "${shared_up_count}" "孤儿 non-managed 上游 shared-up 应被删除"

printf "[PASS] traffic workflow tests passed\n"
