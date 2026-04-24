#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_RENDER_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_RENDER_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"
# shellcheck source=lib/crypto.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/crypto.sh"

ps_render_record_engine_status() {
  local engine="${1}"
  local ok="${2}"
  local message="${3:-}"
  local ok_bool="false"
  if [[ "${ok}" == "true" ]]; then
    ok_bool="true"
  fi
  ps_manifest_update \
    --arg e "${engine}" \
    --argjson ok "${ok_bool}" \
    --arg msg "${message}" \
    --arg ts "$(ps_now_iso)" \
    '
      .status.render[$e] = ((.status.render[$e] // {})
        + {ok:$ok, message:$msg, checked_at:$ts})
      | if $ok then
          .status.render[$e].last_success_at = $ts
          | .status.render[$e].last_success_message = $msg
        else
          .status.render[$e].last_failure_at = $ts
          | .status.render[$e].last_failure_message = $msg
        end
      | .meta.updated_at = $ts
    '
}

ps_render_validate_reality_manifest_for_engine() {
  local engine="${1:-xray}"
  local row stack_id stack_name private_key public_key short_id server_name dest

  while IFS=$'\t' read -r stack_id stack_name private_key public_key short_id server_name dest; do
    [[ -n "${stack_id}" ]] || continue

    local effective_server_name effective_dest
    effective_server_name="${server_name}"
    if [[ -z "${effective_server_name}" && -n "${dest}" ]]; then
      effective_server_name="${dest%%:*}"
    fi
    effective_dest="${dest}"
    if [[ -z "${effective_dest}" && -n "${effective_server_name}" ]]; then
      effective_dest="${effective_server_name}:443"
    fi

    if [[ -z "${effective_server_name}" ]]; then
      printf "协议栈 %s（%s）REALITY server_name 为空。\n" "${stack_name}" "${stack_id}"
      return 1
    fi
    if [[ ! "${effective_dest}" =~ ^[^:]+:[0-9]{1,5}$ ]]; then
      printf "协议栈 %s（%s）REALITY dest 格式无效：%s\n" "${stack_name}" "${stack_id}" "${effective_dest}"
      return 1
    fi

    if ! ps_is_valid_reality_key "${private_key}"; then
      printf "协议栈 %s（%s）REALITY private_key 格式无效。\n" "${stack_name}" "${stack_id}"
      return 1
    fi
    if [[ -n "${public_key}" ]] && ! ps_is_valid_reality_key "${public_key}"; then
      printf "协议栈 %s（%s）REALITY public_key 格式无效。\n" "${stack_name}" "${stack_id}"
      return 1
    fi
    if ! ps_is_valid_reality_short_id "${short_id}"; then
      printf "协议栈 %s（%s）REALITY short_id 格式无效。\n" "${stack_name}" "${stack_id}"
      return 1
    fi
  done < <(
    jq -r \
      --arg e "${engine}" \
      '.stacks[]?
      | select(.enabled == true and .engine == $e and .security == "reality")
      | [
          .stack_id,
          (.name // .stack_id),
          (.reality.private_key // ""),
          (.reality.public_key // ""),
          (.reality.short_id // ""),
          (.reality.server_name // ""),
          (.reality.dest // "")
        ]
      | @tsv' \
      "${PS_MANIFEST}"
  )

  return 0
}

ps_render_xray_inbounds_json() {
  jq -c '
    [
      (
        .stacks[]?
        | select(.enabled == true and .engine == "xray")
        | if .protocol == "vless" then
            {
              tag: ("stack-" + .stack_id),
              listen: "0.0.0.0",
              port: .port,
              protocol: "vless",
              settings: {
                clients: [
                  (
                    {
                      id: .uuid,
                      email: .name
                    }
                    + (if (.flow // "") != "" then {flow: .flow} else {} end)
                  )
                ],
                decryption: "none"
              },
              streamSettings: (
                {
                  network: (if .transport == "grpc" then "grpc" elif .transport == "xhttp" then "xhttp" else "tcp" end),
                  security: (if .security == "reality" then "reality" elif .security == "tls" then "tls" else "none" end)
                }
                + (if .transport == "grpc" then {grpcSettings: {serviceName: (.grpc.service_name // "grpc")}} else {} end)
                + (if .transport == "xhttp" then {xhttpSettings: {path: (.xhttp.path // "/"), host: (.xhttp.host // "")}} else {} end)
                + (if .security == "tls" then
                    {
                      tlsSettings: {
                        serverName: (.tls.domain // .server),
                        certificates: [
                          {
                            certificateFile: (.tls.fullchain // ""),
                            keyFile: (.tls.key // "")
                          }
                        ]
                      }
                    }
                  elif .security == "reality" then
                    {
                      realitySettings: {
                        show: false,
                        dest: (.reality.dest // ((.reality.server_name // "www.microsoft.com") + ":443")),
                        serverNames: [(.reality.server_name // ((.reality.dest // "") | split(":")[0] // "www.microsoft.com"))],
                        privateKey: (.reality.private_key // ""),
                        shortIds: [(.reality.short_id // "")]
                      }
                    }
                  else {} end)
              )
            }
          elif .protocol == "shadowsocks-2022" then
            {
              tag: ("stack-" + .stack_id),
              listen: "0.0.0.0",
              port: .port,
              protocol: "shadowsocks",
              settings: {
                method: (.ss2022.method // "2022-blake3-aes-128-gcm"),
                password: (.ss2022.password // ""),
                network: "tcp,udp"
              }
            }
            + (if .security == "tls" then
                {
                  streamSettings: {
                    network: "tcp",
                    security: "tls",
                    tlsSettings: {
                      serverName: (.tls.domain // .server),
                      certificates: [
                        {
                          certificateFile: (.tls.fullchain // ""),
                          keyFile: (.tls.key // "")
                        }
                      ]
                    }
                  }
                }
              else {} end)
          else empty end
      ),
      (
        .inbounds[]?
        | select(.enabled != false and .public != true)
        | if .type == "socks" then
            {
              tag: .tag,
              listen: .listen,
              port: .port,
              protocol: "socks",
              settings: (
                if ((.auth.username // "") != "" and (.auth.password // "") != "") then
                  {accounts: [{user: .auth.username, pass: .auth.password}], udp: (.udp // true)}
                else
                  {udp: (.udp // true)}
                end
              )
            }
          elif .type == "http" then
            {
              tag: .tag,
              listen: .listen,
              port: .port,
              protocol: "http",
              settings: (
                if ((.auth.username // "") != "" and (.auth.password // "") != "") then
                  {accounts: [{user: .auth.username, pass: .auth.password}]}
                else
                  {}
                end
              )
            }
          elif .type == "mixed" then
            {
              tag: .tag,
              listen: .listen,
              port: .port,
              protocol: "mixed",
              settings: (
                if ((.auth.username // "") != "" and (.auth.password // "") != "") then
                  {accounts: [{user: .auth.username, pass: .auth.password}], udp: (.udp // true)}
                else
                  {udp: (.udp // true)}
                end
              )
            }
          else empty end
      )
    ]
  ' "${PS_MANIFEST}"
}

ps_render_xray_outbounds_json() {
  jq -c '
    [
      .outbounds[]?
      | select(.enabled != false)
      | if .type == "direct" then
          {tag: .tag, protocol: "freedom"}
        elif .type == "block" then
          {tag: .tag, protocol: "blackhole"}
        elif .type == "dns" then
          {tag: .tag, protocol: "dns"}
        elif .type == "socks5" then
          {
            tag: .tag,
            protocol: "socks",
            settings: {
              servers: [
                {
                  address: .server,
                  port: .port,
                  users: (
                    if ((.auth.username // "") != "" and (.auth.password // "") != "") then
                      [{user: .auth.username, pass: .auth.password}]
                    else
                      []
                    end
                  )
                }
              ]
            }
          }
        elif .type == "http" then
          {
            tag: .tag,
            protocol: "http",
            settings: {
              servers: [
                {
                  address: .server,
                  port: .port,
                  users: (
                    if ((.auth.username // "") != "" and (.auth.password // "") != "") then
                      [{user: .auth.username, pass: .auth.password}]
                    else
                      []
                    end
                  )
                }
              ]
            }
          }
        elif .type == "vless" then
          {
            tag: .tag,
            protocol: "vless",
            settings: {
              vnext: [
                {
                  address: .server,
                  port: .port,
                  users: [{id: .uuid, encryption: "none"}]
                }
              ]
            },
            streamSettings: {
              network: (.network // "tcp"),
              security: "tls",
              tlsSettings: {
                serverName: (.sni // .server),
                fingerprint: (.fingerprint // "chrome")
              }
            }
          }
        elif .type == "shadowsocks" then
          {
            tag: .tag,
            protocol: "shadowsocks",
            settings: {
              servers: [
                {
                  address: .server,
                  port: .port,
                  method: (.method // "2022-blake3-aes-128-gcm"),
                  password: .password
                }
              ]
            }
          }
        elif .type == "selector" then
          {
            tag: .tag,
            protocol: "freedom"
          }
        else empty end
    ]
  ' "${PS_MANIFEST}"
}

ps_render_xray_routes_json() {
  jq -c '
    . as $root
    | [
        .routes[]?
        | select(.enabled != false)
        | (.inbound_tag // []) as $raw_tags
        | (
            [
              $raw_tags[]? as $t
              | (
                  [($root.inbounds[]?.tag | select(. == $t))]
                  + [($root.stacks[]? | select(.stack_id == $t or .name == $t) | ("stack-" + .stack_id))]
                ) as $mapped
              | if ($mapped | length) > 0 then
                  ($mapped[] | select(. != null and . != ""))
                else
                  $t
                end
            ]
            | unique
          ) as $expanded_inbound_tags
        | {
            type: "field",
            outboundTag: .outbound,
            inboundTag: $expanded_inbound_tags,
            domain: (([.domain_suffix[]? | "domain:" + .] + [.domain_keyword[]? | "keyword:" + .])),
            ip: (.ip_cidr // []),
            network: ((.network // []) | map(ascii_downcase) | join(","))
          }
        | with_entries(select(.value != [] and .value != "" and .value != null))
        | select((has("inboundTag")) or (has("domain")) or (has("ip")) or (has("network")))
      ]
  ' "${PS_MANIFEST}"
}

ps_render_xray_config() {
  ps_print_header "渲染 Xray 配置"
  local template="${PS_TEMPLATES_DIR}/xray/base.json.tpl"
  if [[ ! -f "${template}" ]]; then
    ps_log_error "缺少 Xray 模板：${template}"
    ps_render_record_engine_status xray false "缺少模板文件"
    return 1
  fi

  local config_path xray_bin
  config_path="$(ps_engine_config_path xray)"
  xray_bin="$(ps_engine_binary xray)"

  local log_json inbounds_json outbounds_json routes_json candidate validate_log validate_message
  log_json="$(jq -c --arg xa "${PS_LOG_DIR}/xray-access.log" --arg xe "${PS_LOG_DIR}/xray-error.log" '.logs | {loglevel:(.level // "warning"),access:(.xray_access // $xa),error:(.xray_error // $xe),dnsLog:(.dns_log // false),maskAddress:(.mask_address // "quarter")}' "${PS_MANIFEST}")"
  if ! validate_message="$(ps_render_validate_reality_manifest_for_engine xray)"; then
    validate_message="$(ps_strip_ansi "${validate_message}")"
    [[ -n "${validate_message}" ]] || validate_message="REALITY 参数校验失败"
    ps_log_error "Xray 配置渲染前校验失败，已保留旧配置。原因：${validate_message}"
    ps_render_record_engine_status xray false "${validate_message}"
    return 1
  fi
  inbounds_json="$(ps_render_xray_inbounds_json)"
  outbounds_json="$(ps_render_xray_outbounds_json)"
  routes_json="$(ps_render_xray_routes_json)"

  candidate="$(mktemp --suffix=.json)"
  jq \
    --argjson log "${log_json}" \
    --argjson inbounds "${inbounds_json}" \
    --argjson outbounds "${outbounds_json}" \
    --argjson routes "${routes_json}" \
    '.log = $log | .inbounds = $inbounds | .outbounds = $outbounds | .routing.rules = $routes' \
    "${template}" >"${candidate}"

  if [[ -x "${xray_bin}" ]]; then
    validate_log="$(mktemp --suffix=.log)"
    if ! "${xray_bin}" run -test -c "${candidate}" >"${validate_log}" 2>&1; then
      validate_message="$(tail -n 1 "${validate_log}" 2>/dev/null || true)"
      validate_message="$(ps_strip_ansi "${validate_message}")"
      [[ -n "${validate_message}" ]] || validate_message="配置校验失败"
      ps_log_error "Xray 配置校验失败，已保留旧配置。原因：${validate_message}"
      ps_render_record_engine_status xray false "${validate_message}"
      rm -f "${validate_log}"
      rm -f "${candidate}"
      return 1
    fi
    rm -f "${validate_log}"
  else
    ps_log_warn "未找到 xray，已跳过 Xray 配置校验"
  fi

  ps_backup_file_if_exists "${config_path}" "xray-config" >/dev/null || true
  ps_atomic_replace_file "${candidate}" "${config_path}"
  ps_render_record_engine_status xray true "渲染成功"
  ps_log_success "Xray 配置已渲染：${config_path}"
}

ps_render_singbox_inbounds_json() {
  jq -c '
    [
      (
        .stacks[]?
        | select(.enabled == true and .engine == "singbox")
        | if .protocol == "vless" then
            {
              type: "vless",
              tag: ("stack-" + .stack_id),
              listen: "::",
              listen_port: .port,
              users: [
                (
                  {
                    uuid: .uuid
                  }
                  + (if (.flow // "") != "" then {flow: .flow} else {} end)
                )
              ],
              tls: (
                if .security == "tls" then
                  {
                    enabled: true,
                    server_name: (.tls.domain // .server),
                    certificate_path: (.tls.fullchain // ""),
                    key_path: (.tls.key // "")
                  }
                elif .security == "reality" then
                  {
                    enabled: true,
                    reality: {
                      enabled: true,
                      handshake: {
                        server: ((.reality.dest // ((.reality.server_name // "www.microsoft.com") + ":443")) | split(":")[0]),
                        server_port: (((.reality.dest // ((.reality.server_name // "www.microsoft.com") + ":443")) | split(":")[1] // "443") | tonumber)
                      },
                      private_key: (.reality.private_key // ""),
                      short_id: [(.reality.short_id // "")]
                    }
                  }
                else
                  {enabled: false}
                end
              ),
              transport: (
                if .transport == "grpc" then
                  {type: "grpc", service_name: (.grpc.service_name // "grpc")}
                elif .transport == "xhttp" then
                  {type: "http", path: (.xhttp.path // "/")}
                else
                  {type: "tcp"}
                end
              )
            }
          elif .protocol == "shadowsocks-2022" then
            {
              type: "shadowsocks",
              tag: ("stack-" + .stack_id),
              listen: "::",
              listen_port: .port,
              method: (.ss2022.method // "2022-blake3-aes-128-gcm"),
              password: (.ss2022.password // ""),
              network: "tcp,udp"
            }
            + (if .security == "tls" then
                {
                  tls: {
                    enabled: true,
                    server_name: (.tls.domain // .server),
                    certificate_path: (.tls.fullchain // ""),
                    key_path: (.tls.key // "")
                  }
                }
              else {} end)
          else empty end
      ),
      (
        .inbounds[]?
        | select(.enabled != false and .public != true)
        | if .type == "socks" then
            {
              type: "socks",
              tag: .tag,
              listen: .listen,
              listen_port: .port,
              users: (
                if ((.auth.username // "") != "" and (.auth.password // "") != "") then
                  [{username: .auth.username, password: .auth.password}]
                else
                  []
                end
              )
            }
          elif .type == "http" then
            {
              type: "http",
              tag: .tag,
              listen: .listen,
              listen_port: .port,
              users: (
                if ((.auth.username // "") != "" and (.auth.password // "") != "") then
                  [{username: .auth.username, password: .auth.password}]
                else
                  []
                end
              )
            }
          elif .type == "mixed" then
            {
              type: "mixed",
              tag: .tag,
              listen: .listen,
              listen_port: .port,
              users: (
                if ((.auth.username // "") != "" and (.auth.password // "") != "") then
                  [{username: .auth.username, password: .auth.password}]
                else
                  []
                end
              )
            }
          else empty end
      )
    ]
  ' "${PS_MANIFEST}"
}

ps_render_singbox_outbounds_json() {
  jq -c '
    [
      .outbounds[]?
      | select(.enabled != false)
      | if .type == "direct" then
          {type: "direct", tag: .tag}
        elif .type == "block" then
          {type: "block", tag: .tag}
        elif .type == "socks5" then
          {
            type: "socks",
            tag: .tag,
            server: .server,
            server_port: .port,
            username: (.auth.username // ""),
            password: (.auth.password // "")
          }
        elif .type == "http" then
          {
            type: "http",
            tag: .tag,
            server: .server,
            server_port: .port,
            username: (.auth.username // ""),
            password: (.auth.password // "")
          }
        elif .type == "vless" then
          {
            type: "vless",
            tag: .tag,
            server: .server,
            server_port: .port,
            uuid: .uuid,
            tls: {
              enabled: true,
              server_name: (.sni // .server),
              utls: {
                enabled: true,
                fingerprint: (.fingerprint // "chrome")
              }
            },
            transport: {
              type: (.network // "tcp")
            }
          }
        elif .type == "shadowsocks" then
          {
            type: "shadowsocks",
            tag: .tag,
            server: .server,
            server_port: .port,
            method: (.method // "2022-blake3-aes-128-gcm"),
            password: .password
          }
        elif .type == "selector" then
          {
            type: "selector",
            tag: .tag,
            outbounds: (.members // ["direct"]),
            default: ((.members // ["direct"])[0])
          }
        else empty end
      | with_entries(select(.value != "" and .value != [] and .value != null))
    ]
  ' "${PS_MANIFEST}"
}

ps_render_singbox_routes_json() {
  jq -c '
    . as $root
    | [
        .routes[]?
        | select(.enabled != false)
        | (.inbound_tag // []) as $raw_tags
        | (
            [
              $raw_tags[]? as $t
              | (
                  [($root.inbounds[]?.tag | select(. == $t))]
                  + [($root.stacks[]? | select(.stack_id == $t or .name == $t) | ("stack-" + .stack_id))]
                ) as $mapped
              | if ($mapped | length) > 0 then
                  ($mapped[] | select(. != null and . != ""))
                else
                  $t
                end
            ]
            | unique
          ) as $expanded_inbound_tags
        | {
            outbound: .outbound,
            inbound: $expanded_inbound_tags,
            domain_suffix: (.domain_suffix // []),
            domain_keyword: (.domain_keyword // []),
            ip_cidr: (.ip_cidr // []),
            network: ((.network // []) | map(ascii_downcase))
          }
        | with_entries(select(.value != [] and .value != "" and .value != null))
        | select((has("inbound")) or (has("domain_suffix")) or (has("domain_keyword")) or (has("ip_cidr")) or (has("network")))
      ]
  ' "${PS_MANIFEST}"
}

ps_render_singbox_config() {
  ps_print_header "渲染 sing-box 配置"
  local template="${PS_TEMPLATES_DIR}/singbox/base.json.tpl"
  if [[ ! -f "${template}" ]]; then
    ps_log_error "缺少 sing-box 模板：${template}"
    ps_render_record_engine_status singbox false "缺少模板文件"
    return 1
  fi

  local config_path singbox_bin
  config_path="$(ps_engine_config_path singbox)"
  singbox_bin="$(ps_engine_binary singbox)"

  local inbounds_json outbounds_json routes_json final_tag candidate validate_log validate_message
  inbounds_json="$(ps_render_singbox_inbounds_json)"
  outbounds_json="$(ps_render_singbox_outbounds_json)"
  routes_json="$(ps_render_singbox_routes_json)"
  final_tag="$(jq -r '.routes | sort_by(.priority) | map(select(.enabled != false)) | if length == 0 then "direct" else .[length - 1].outbound end' "${PS_MANIFEST}")"

  if ! validate_message="$(ps_render_validate_reality_manifest_for_engine singbox)"; then
    validate_message="$(ps_strip_ansi "${validate_message}")"
    [[ -n "${validate_message}" ]] || validate_message="REALITY 参数校验失败"
    ps_log_error "sing-box 配置渲染前校验失败，已保留旧配置。原因：${validate_message}"
    ps_render_record_engine_status singbox false "${validate_message}"
    return 1
  fi

  candidate="$(mktemp --suffix=.json)"
  jq \
    --arg level "$(jq -r '.logs.level // "info"' "${PS_MANIFEST}")" \
    --argjson inbounds "${inbounds_json}" \
    --argjson outbounds "${outbounds_json}" \
    --argjson routes "${routes_json}" \
    --arg final "${final_tag}" \
    '.log.level = $level | .inbounds = $inbounds | .outbounds = $outbounds | .route.rules = $routes | .route.final = $final' \
    "${template}" >"${candidate}"

  if [[ -x "${singbox_bin}" ]]; then
    validate_log="$(mktemp --suffix=.log)"
    if ! "${singbox_bin}" check -c "${candidate}" >"${validate_log}" 2>&1; then
      validate_message="$(tail -n 1 "${validate_log}" 2>/dev/null || true)"
      validate_message="$(ps_strip_ansi "${validate_message}")"
      [[ -n "${validate_message}" ]] || validate_message="配置校验失败"
      ps_log_error "sing-box 配置校验失败，已保留旧配置。原因：${validate_message}"
      ps_render_record_engine_status singbox false "${validate_message}"
      rm -f "${validate_log}"
      rm -f "${candidate}"
      return 1
    fi
    rm -f "${validate_log}"
  else
    ps_log_warn "未找到 sing-box，已跳过配置校验"
  fi

  ps_backup_file_if_exists "${config_path}" "singbox-config" >/dev/null || true
  ps_atomic_replace_file "${candidate}" "${config_path}"
  ps_render_record_engine_status singbox true "渲染成功"
  ps_log_success "sing-box 配置已渲染：${config_path}"
}

ps_render_all() {
  local ok=0
  ps_render_xray_config || ok=1
  ps_render_singbox_config || ok=1

  if [[ "${ok}" -eq 0 ]]; then
    ps_log_success "渲染完成"
    return 0
  fi
  ps_log_warn "渲染完成，但存在告警"
  return 1
}
