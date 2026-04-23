#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_RENDER_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_RENDER_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"

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
                        dest: (.reality.dest // (.server + ":443")),
                        serverNames: [(.reality.server_name // .server)],
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
    [
      .routes[]?
      | select(.enabled != false)
      | {
          type: "field",
          outboundTag: .outbound,
          inboundTag: (.inbound_tag // []),
          domain: (([.domain_suffix[]? | "domain:" + .] + [.domain_keyword[]? | "keyword:" + .])),
          ip: (.ip_cidr // []),
          network: ((.network // []) | map(ascii_downcase) | join(","))
        }
      | with_entries(select(.value != [] and .value != "" and .value != null))
    ]
  ' "${PS_MANIFEST}"
}

ps_render_xray_config() {
  ps_print_header "渲染 Xray 配置"
  local template="${PS_TEMPLATES_DIR}/xray/base.json.tpl"
  if [[ ! -f "${template}" ]]; then
    ps_log_error "Missing xray template: ${template}"
    return 1
  fi

  local log_json inbounds_json outbounds_json routes_json candidate
  log_json="$(jq -c '.logs | {loglevel:(.level // "warning"),access:(.xray_access // "/var/log/proxy-stack/xray-access.log"),error:(.xray_error // "/var/log/proxy-stack/xray-error.log"),dnsLog:(.dns_log // false),maskAddress:(.mask_address // "quarter")}' "${PS_MANIFEST}")"
  inbounds_json="$(ps_render_xray_inbounds_json)"
  outbounds_json="$(ps_render_xray_outbounds_json)"
  routes_json="$(ps_render_xray_routes_json)"

  candidate="$(mktemp)"
  jq \
    --argjson log "${log_json}" \
    --argjson inbounds "${inbounds_json}" \
    --argjson outbounds "${outbounds_json}" \
    --argjson routes "${routes_json}" \
    '.log = $log | .inbounds = $inbounds | .outbounds = $outbounds | .routing.rules = $routes' \
    "${template}" >"${candidate}"

  if ps_command_exists xray; then
    if ! xray run -test -c "${candidate}" >/dev/null 2>&1; then
      ps_log_error "Xray 配置校验失败，已保留旧配置。"
      rm -f "${candidate}"
      return 1
    fi
  else
    ps_log_warn "未找到 xray，已跳过 Xray 配置校验"
  fi

  ps_backup_file_if_exists "${PS_XRAY_CONFIG}" "xray-config" >/dev/null || true
  ps_atomic_replace_file "${candidate}" "${PS_XRAY_CONFIG}"
  ps_log_success "Xray 配置已渲染：${PS_XRAY_CONFIG}"
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
                        server: ((.reality.dest // .server) | split(":")[0]),
                        server_port: (((.reality.dest // (.server + ":443")) | split(":")[1] // "443") | tonumber)
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
        elif .type == "dns" then
          {type: "dns", tag: .tag}
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
    [
      .routes[]?
      | select(.enabled != false)
      | {
          outbound: .outbound,
          inbound: (.inbound_tag // []),
          domain_suffix: (.domain_suffix // []),
          domain_keyword: (.domain_keyword // []),
          ip_cidr: (.ip_cidr // []),
          network: ((.network // []) | map(ascii_lowercase))
        }
      | with_entries(select(.value != [] and .value != "" and .value != null))
    ]
  ' "${PS_MANIFEST}"
}

ps_render_singbox_config() {
  ps_print_header "渲染 sing-box 配置"
  local template="${PS_TEMPLATES_DIR}/singbox/base.json.tpl"
  if [[ ! -f "${template}" ]]; then
    ps_log_error "Missing sing-box template: ${template}"
    return 1
  fi

  local inbounds_json outbounds_json routes_json final_tag candidate
  inbounds_json="$(ps_render_singbox_inbounds_json)"
  outbounds_json="$(ps_render_singbox_outbounds_json)"
  routes_json="$(ps_render_singbox_routes_json)"
  final_tag="$(jq -r '.routes | sort_by(.priority) | map(select(.enabled != false)) | last?.outbound // "direct"' "${PS_MANIFEST}")"

  candidate="$(mktemp)"
  jq \
    --arg level "$(jq -r '.logs.level // "info"' "${PS_MANIFEST}")" \
    --argjson inbounds "${inbounds_json}" \
    --argjson outbounds "${outbounds_json}" \
    --argjson routes "${routes_json}" \
    --arg final "${final_tag}" \
    '.log.level = $level | .inbounds = $inbounds | .outbounds = $outbounds | .route.rules = $routes | .route.final = $final' \
    "${template}" >"${candidate}"

  if ps_command_exists sing-box; then
    if ! sing-box check -c "${candidate}" >/dev/null 2>&1; then
      ps_log_error "sing-box 配置校验失败，已保留旧配置。"
      rm -f "${candidate}"
      return 1
    fi
  else
    ps_log_warn "未找到 sing-box，已跳过配置校验"
  fi

  ps_backup_file_if_exists "${PS_SINGBOX_CONFIG}" "singbox-config" >/dev/null || true
  ps_atomic_replace_file "${candidate}" "${PS_SINGBOX_CONFIG}"
  ps_log_success "sing-box 配置已渲染：${PS_SINGBOX_CONFIG}"
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
