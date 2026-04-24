#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_STATUS_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_STATUS_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"
# shellcheck source=lib/systemd.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/systemd.sh"

ps_status_section() {
  local title="${1}"
  printf "\n[%s]\n" "${title}"
}

ps_status_launcher_candidates() {
  local candidates=("/usr/local/bin/kprxy" "${HOME}/.local/bin/kprxy")
  if [[ -n "${PS_BOOTSTRAP_LAUNCHER_PATH:-}" ]]; then
    candidates+=("${PS_BOOTSTRAP_LAUNCHER_PATH}")
  fi
  printf '%s\n' "${candidates[@]}" | awk '!seen[$0]++'
}

ps_status_launcher_installed() {
  local launcher
  while read -r launcher; do
    [[ -n "${launcher}" ]] || continue
    if [[ -x "${launcher}" ]]; then
      printf "%s\n" "${launcher}"
      return 0
    fi
  done < <(ps_status_launcher_candidates)
  return 1
}

ps_status_installation_section() {
  ps_status_section "安装状态"

  local launcher runtime_ok home_ok manifest_ok services_count
  launcher="$(ps_status_launcher_installed || true)"
  runtime_ok="否"
  home_ok="否"
  manifest_ok="否"
  services_count=0

  if [[ -d "${PS_RUNTIME_DIR}" ]]; then runtime_ok="是"; fi
  if [[ -d "${PS_HOME_DIR}" ]]; then home_ok="是"; fi
  if [[ -f "${PS_MANIFEST}" ]]; then manifest_ok="是"; fi

  if ps_systemd_is_available; then
    if ps_systemd_service_exists "${PS_XRAY_SERVICE}"; then services_count=$((services_count + 1)); fi
    if ps_systemd_service_exists "${PS_SINGBOX_SERVICE}"; then services_count=$((services_count + 1)); fi
  fi

  if [[ -n "${launcher}" ]]; then
    printf -- "- 启动器：已安装（%s）\n" "${launcher}"
  else
    printf -- "- 启动器：未安装\n"
  fi
  printf -- "- 项目目录：%s（路径=%s）\n" "${home_ok}" "${PS_HOME_DIR}"
  printf -- "- 运行目录：%s（路径=%s）\n" "${runtime_ok}" "${PS_RUNTIME_DIR}"
  printf -- "- 状态文件：%s（路径=%s）\n" "${manifest_ok}" "${PS_MANIFEST}"
  printf -- "- kprxy systemd 单元数量：%s\n" "${services_count}"

  if [[ -z "${launcher}" && ( "${home_ok}" == "是" || "${manifest_ok}" == "是" || "${services_count}" -gt 0 ) ]]; then
    printf -- "- 检测结论：存在残留，疑似“部分卸载”。\n"
  elif [[ -n "${launcher}" && "${home_ok}" == "否" && "${manifest_ok}" == "否" ]]; then
    printf -- "- 检测结论：仅剩启动器，安装状态不完整。\n"
  else
    printf -- "- 检测结论：安装状态正常。\n"
  fi
}

ps_status_cmdline_of_pid() {
  local pid="${1}"
  ps -p "${pid}" -o args= 2>/dev/null || true
}

ps_status_pid_in_list() {
  local target_pid="${1}"
  shift || true
  local pid
  for pid in "$@"; do
    if [[ "${pid}" == "${target_pid}" ]]; then
      return 0
    fi
  done
  return 1
}

ps_status_collect_kprxy_pids() {
  local pids=()

  local xsvc ssvc xmain smain
  xsvc="$(ps_engine_service_name xray)"
  ssvc="$(ps_engine_service_name singbox)"

  if ps_systemd_is_available; then
    xmain="$(systemctl show -p MainPID --value "${xsvc}" 2>/dev/null || printf "0")"
    smain="$(systemctl show -p MainPID --value "${ssvc}" 2>/dev/null || printf "0")"
    if [[ "${xmain}" =~ ^[0-9]+$ && "${xmain}" -gt 0 ]]; then pids+=("${xmain}"); fi
    if [[ "${smain}" =~ ^[0-9]+$ && "${smain}" -gt 0 ]]; then pids+=("${smain}"); fi
  fi

  local pid cmdline
  while read -r pid; do
    [[ -n "${pid}" ]] || continue
    cmdline="$(ps_status_cmdline_of_pid "${pid}")"
    if [[ "${cmdline}" == *"$(ps_engine_config_path xray)"* ]] || [[ "${cmdline}" == *"$(ps_engine_config_path singbox)"* ]] || [[ "${cmdline}" == *"${PS_HOME_DIR}"* ]]; then
      pids+=("${pid}")
    fi
  done < <(pgrep -f 'xray|sing-box' 2>/dev/null || true)

  if [[ "${#pids[@]}" -eq 0 ]]; then
    return 0
  fi

  printf "%s\n" "${pids[@]}" | awk '!seen[$0]++'
}

ps_status_is_kprxy_pid() {
  local target_pid="${1}"
  local pid
  while read -r pid; do
    [[ -n "${pid}" ]] || continue
    if [[ "${pid}" == "${target_pid}" ]]; then
      return 0
    fi
  done < <(ps_status_collect_kprxy_pids)
  return 1
}

ps_status_process_pids() {
  local engine="${1}"
  local bin_name pattern
  case "${engine}" in
    xray)
      bin_name="xray"
      ;;
    singbox)
      bin_name="sing-box"
      ;;
    *)
      return 1
      ;;
  esac

  pattern="$(ps_engine_binary "${engine}")"
  if [[ -n "${pattern}" ]]; then
    pgrep -f "${pattern}" 2>/dev/null || pgrep -x "${bin_name}" 2>/dev/null || true
    return 0
  fi
  pgrep -x "${bin_name}" 2>/dev/null || true
}

ps_status_engine_section() {
  ps_status_section "内核状态"

  local engine label service bin cfg
  for engine in xray singbox; do
    label="Xray"
    [[ "${engine}" == "singbox" ]] && label="sing-box"
    service="$(ps_engine_service_name "${engine}")"
    bin="$(ps_engine_binary "${engine}")"
    cfg="$(ps_engine_config_path "${engine}")"

    mapfile -t pids < <(ps_status_process_pids "${engine}")

    local runtime_text
    if [[ "${#pids[@]}" -gt 0 ]]; then
      runtime_text="运行中"
    else
      runtime_text="未运行"
    fi

    local systemd_text="未由 systemd 托管"
    if ps_systemd_is_available && ps_systemd_service_exists "${service}"; then
      local mainpid
      mainpid="$(systemctl show -p MainPID --value "${service}" 2>/dev/null || printf "0")"
      if [[ "${mainpid}" =~ ^[0-9]+$ && "${mainpid}" -gt 0 ]]; then
        systemd_text="systemd 托管（${service}.service, MainPID ${mainpid}）"
      else
        systemd_text="systemd 已配置（${service}.service，当前未激活）"
      fi
    fi

    if [[ "${#pids[@]}" -gt 0 ]]; then
      printf -- "- %s：%s（PID %s，%s）\n" "${label}" "${runtime_text}" "$(IFS=,; echo "${pids[*]}")" "${systemd_text}"
    else
      printf -- "- %s：%s（%s）\n" "${label}" "${runtime_text}" "${systemd_text}"
    fi

    printf "  可执行文件：%s\n" "${bin}"
    if [[ -x "${bin}" ]]; then
      printf "  二进制安装：是\n"
    else
      printf "  二进制安装：否\n"
    fi
    printf "  配置路径：%s\n" "${cfg}"
    printf "  服务名：%s\n" "${service}.service"
  done
}

ps_status_ports_section() {
  ps_status_section "端口监听"

  if [[ ! -f "${PS_MANIFEST}" ]]; then
    printf -- "- 未找到 manifest，无法检查端口。\n"
    return 0
  fi

  local row_count=0
  while IFS='|' read -r scope name port note; do
    [[ -n "${port}" ]] || continue
    row_count=$((row_count + 1))

    if [[ "${note}" == "remote" ]]; then
      printf -- "- [%s] %s 端口 %s：远端目标端口，不执行本机监听判定\n" "${scope}" "${name}" "${port}"
      continue
    fi

    local state owner proc pid
    state="未监听"
    owner="-"
    if ps_port_is_listening "${port}"; then
      state="监听中"
      owner="$(ps_port_listener_owner "${port}" || true)"
    fi

    if [[ -n "${owner}" ]]; then
      IFS='|' read -r proc pid <<<"${owner}"
      printf -- "- [%s] %s 端口 %s：%s（进程=%s，PID=%s）\n" "${scope}" "${name}" "${port}" "${state}" "${proc:-未知}" "${pid:-未知}"
    else
      printf -- "- [%s] %s 端口 %s：%s\n" "${scope}" "${name}" "${port}" "${state}"
    fi
  done < <(
    jq -r '
      [
        (.stacks[]? | "协议栈|" + (.name // .stack_id // "-") + "|" + ((.port // empty)|tostring) + "|listen"),
        (.inbounds[]? | "本地/入站|" + (.tag // "-") + "|" + ((.port // empty)|tostring) + "|listen"),
        (.forwardings[]? | "转发监听|" + (.name // .forward_id // "-") + "|" + ((.listen_port // empty)|tostring) + "|listen"),
        (.forwardings[]? | "转发目标|" + (.name // .forward_id // "-") + "|" + ((.target_port // empty)|tostring) + "|remote")
      ]
      | .[]
    ' "${PS_MANIFEST}"
  )

  if [[ "${row_count}" -eq 0 ]]; then
    printf -- "- manifest 中未记录需要检查的端口。\n"
  fi
}

ps_status_validate_config_now() {
  local engine="${1}"
  local cfg bin
  cfg="$(ps_engine_config_path "${engine}")"
  bin="$(ps_engine_binary "${engine}")"

  if [[ ! -f "${cfg}" ]]; then
    printf "配置文件不存在"
    return 1
  fi

  if [[ ! -x "${bin}" ]]; then
    printf "二进制不存在，无法校验"
    return 2
  fi

  case "${engine}" in
    xray)
      if "${bin}" run -test -c "${cfg}" >/dev/null 2>&1; then
        printf "校验通过"
        return 0
      fi
      ;;
    singbox)
      if "${bin}" check -c "${cfg}" >/dev/null 2>&1; then
        printf "校验通过"
        return 0
      fi
      ;;
  esac

  printf "校验失败"
  return 1
}

ps_status_config_section() {
  ps_status_section "配置状态"

  local engine label cfg exists mtime render_ok render_msg validate_msg
  for engine in xray singbox; do
    label="Xray"
    [[ "${engine}" == "singbox" ]] && label="sing-box"

    cfg="$(ps_engine_config_path "${engine}")"
    if [[ -f "${cfg}" ]]; then
      exists="存在"
      mtime="$(stat -c '%y' "${cfg}" 2>/dev/null || date -r "${cfg}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf -- '-')"
    else
      exists="不存在"
      mtime="-"
    fi

    render_ok="$(jq -r --arg e "${engine}" '.status.render[$e].ok // empty' "${PS_MANIFEST}" 2>/dev/null || true)"
    render_msg="$(jq -r --arg e "${engine}" '.status.render[$e].message // "无记录"' "${PS_MANIFEST}" 2>/dev/null || printf '无记录')"

    validate_msg="$(ps_status_validate_config_now "${engine}" || true)"

    printf -- "- %s\n" "${label}"
    printf "  配置文件：%s（%s）\n" "${cfg}" "${exists}"
    printf "  最后修改：%s\n" "${mtime}"
    if [[ -n "${render_ok}" ]]; then
      printf "  最近渲染/检查：%s（ok=%s）\n" "${render_msg}" "${render_ok}"
    else
      printf "  最近渲染/检查：%s\n" "${render_msg}"
    fi
    printf "  当前校验：%s\n" "${validate_msg}"
  done
}

ps_status_unapplied_stacks_for_engine() {
  local engine="${1:-xray}"
  jq -r \
    --arg e "${engine}" \
    '
      (.status.render[$e].last_success_at // "") as $success_at
      | [
          .stacks[]?
          | select(.enabled == true and .engine == $e)
        ] as $enabled
      | if $success_at == "" then
          $enabled
        else
          [
            $enabled[]
            | select((.updated_at // .created_at // "") > $success_at)
          ]
        end
      | map(.name // .stack_id)
      | unique
      | .[]
    ' "${PS_MANIFEST}" 2>/dev/null || true
}

ps_status_apply_section() {
  ps_status_section "应用状态"

  local engine label saved_count render_ok render_msg render_checked
  local last_success_at last_failure_at last_failure_msg
  for engine in xray singbox; do
    label="Xray"
    [[ "${engine}" == "singbox" ]] && label="sing-box"

    saved_count="$(jq -r --arg e "${engine}" '[.stacks[]? | select(.enabled == true and .engine == $e)] | length' "${PS_MANIFEST}" 2>/dev/null || printf '0')"
    render_ok="$(jq -r --arg e "${engine}" '.status.render[$e].ok // false' "${PS_MANIFEST}" 2>/dev/null || printf 'false')"
    render_msg="$(jq -r --arg e "${engine}" '.status.render[$e].message // "无记录"' "${PS_MANIFEST}" 2>/dev/null || printf '无记录')"
    render_checked="$(jq -r --arg e "${engine}" '.status.render[$e].checked_at // ""' "${PS_MANIFEST}" 2>/dev/null || true)"
    last_success_at="$(jq -r --arg e "${engine}" '.status.render[$e].last_success_at // ""' "${PS_MANIFEST}" 2>/dev/null || true)"
    last_failure_at="$(jq -r --arg e "${engine}" '.status.render[$e].last_failure_at // ""' "${PS_MANIFEST}" 2>/dev/null || true)"
    last_failure_msg="$(jq -r --arg e "${engine}" '.status.render[$e].last_failure_message // ""' "${PS_MANIFEST}" 2>/dev/null || true)"

    mapfile -t unapplied < <(ps_status_unapplied_stacks_for_engine "${engine}")
    local unapplied_text="无"
    if [[ "${#unapplied[@]}" -gt 0 ]]; then
      unapplied_text="$(IFS='，'; echo "${unapplied[*]}")"
    fi

    printf -- "- %s\n" "${label}"
    printf "  当前运行配置：%s\n" "$(ps_engine_config_path "${engine}")"
    printf "  已保存服务定义：%s\n" "${saved_count}"
    printf "  最近渲染尝试：%s（ok=%s）" "${render_msg}" "${render_ok}"
    [[ -n "${render_checked}" ]] && printf "（时间=%s）" "${render_checked}"
    printf "\n"
    if [[ -n "${last_success_at}" ]]; then
      printf "  最近成功应用：%s\n" "${last_success_at}"
    else
      printf "  最近成功应用：无记录\n"
    fi
    if [[ -n "${last_failure_at}" ]]; then
      printf "  最近渲染失败：%s" "${last_failure_at}"
      [[ -n "${last_failure_msg}" ]] && printf "（%s）" "${last_failure_msg}"
      printf "\n"
    fi
    printf "  未应用服务：%s\n" "${unapplied_text}"
  done
}

ps_status_systemd_section() {
  ps_status_section "systemd 状态"

  if ! ps_systemd_is_available; then
    printf -- "- 当前系统不可用 systemctl。\n"
    return 0
  fi

  local engine label service
  for engine in xray singbox; do
    label="Xray"
    [[ "${engine}" == "singbox" ]] && label="sing-box"
    service="$(ps_engine_service_name "${engine}")"

    if ps_systemd_service_exists "${service}"; then
      printf -- "- %s：%s.service active=%s enabled=%s\n" \
        "${label}" "${service}" "$(ps_systemd_active_state "${service}")" "$(ps_systemd_enabled_state "${service}")"
    else
      printf -- "- %s：未检测到 %s.service（当前未由 systemd 托管）\n" "${label}" "${service}"
    fi
  done
}

ps_status_cert_renew_task_exists() {
  if [[ -f /etc/cron.d/kprxy-acme || -f /etc/cron.d/proxy-stack-acme ]]; then
    return 0
  fi

  if crontab -l 2>/dev/null | grep -Eq 'acme\.sh.*(kprxy|xray|sing-box)'; then
    return 0
  fi

  return 1
}

ps_status_cert_section() {
  ps_status_section "证书状态"

  if [[ ! -f "${PS_MANIFEST}" ]]; then
    printf -- "- 未找到 manifest，无法检查证书。\n"
    return 0
  fi

  local has_cert
  has_cert="$(jq -r '(.certificates | length) > 0' "${PS_MANIFEST}" 2>/dev/null || printf "false")"
  if [[ "${has_cert}" != "true" ]]; then
    printf -- "- 未配置证书。\n"
    return 0
  fi

  while IFS='|' read -r domain fullchain key renew_enabled; do
    local fullchain_ok key_ok
    fullchain_ok="未安装"
    key_ok="未安装"
    if [[ -f "${fullchain}" ]]; then fullchain_ok="已安装"; fi
    if [[ -f "${key}" ]]; then key_ok="已安装"; fi

    printf -- "- 域名：%s\n" "${domain}"
    printf "  fullchain：%s（%s）\n" "${fullchain}" "${fullchain_ok}"
    printf "  私钥：%s（%s）\n" "${key}" "${key_ok}"

    if [[ -f "${fullchain}" ]] && ps_command_exists openssl; then
      local issuer subject not_before not_after end_ts now_ts remain_days
      issuer="$(openssl x509 -in "${fullchain}" -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
      subject="$(openssl x509 -in "${fullchain}" -noout -subject 2>/dev/null | sed 's/^subject=//')"
      not_before="$(openssl x509 -in "${fullchain}" -noout -startdate 2>/dev/null | sed 's/^notBefore=//')"
      not_after="$(openssl x509 -in "${fullchain}" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
      end_ts="$(date -d "${not_after}" +%s 2>/dev/null || printf 0)"
      now_ts="$(date +%s)"
      if [[ "${end_ts}" -gt 0 ]]; then
        remain_days="$(( (end_ts - now_ts) / 86400 ))"
      else
        remain_days="-"
      fi

      printf "  颁发者：%s\n" "${issuer:--}"
      printf "  主题：%s\n" "${subject:--}"
      printf "  notBefore：%s\n" "${not_before:--}"
      printf "  notAfter：%s\n" "${not_after:--}"
      printf "  剩余天数：%s\n" "${remain_days}"
    else
      printf "  证书解析：不可用（缺少文件或 openssl）\n"
    fi

    if [[ "${renew_enabled}" == "true" ]]; then
      if ps_status_cert_renew_task_exists; then
        printf "  自动续费：已启用（已检测到续费任务）\n"
      else
        printf "  自动续费：已启用（未检测到续费任务）\n"
      fi
    else
      printf "  自动续费：未启用\n"
    fi
  done < <(jq -r '.certificates | to_entries[] | "\(.key)|\(.value.fullchain // "")|\(.value.key // "")|\(.value.renew_enabled // false)"' "${PS_MANIFEST}")
}

ps_status_detect_3xui() {
  local detected=0
  local evidence=()

  local probe_paths=(
    /etc/x-ui
    /etc/3x-ui
    /usr/local/x-ui
    /usr/local/3x-ui
    /opt/x-ui
    /opt/3x-ui
    /usr/local/etc/x-ui
    /usr/local/etc/3x-ui
    /usr/local/bin/x-ui
    /usr/local/bin/3x-ui
    /usr/bin/x-ui
    /usr/bin/3x-ui
    /etc/x-ui/x-ui.db
    /etc/3x-ui/x-ui.db
    /usr/local/x-ui/x-ui.db
    /usr/local/etc/x-ui/x-ui.db
  )

  local p
  for p in "${probe_paths[@]}"; do
    if [[ -e "${p}" ]]; then
      detected=1
      evidence+=("路径:${p}")
    fi
  done

  if ps_systemd_is_available; then
    local unit
    while read -r unit; do
      [[ -n "${unit}" ]] || continue
      detected=1
      evidence+=("服务:${unit}")
    done < <(
      systemctl list-unit-files --type=service --no-legend 2>/dev/null \
        | awk '{print $1}' \
        | grep -E '^(x-ui|3x-ui)(@.*)?\.service$' || true
    )

    while read -r unit; do
      [[ -n "${unit}" ]] || continue
      detected=1
      evidence+=("运行中服务:${unit}")
    done < <(
      systemctl list-units --type=service --all --no-legend 2>/dev/null \
        | awk '{print $1}' \
        | grep -E '^(x-ui|3x-ui)(@.*)?\.service$' || true
    )
  fi

  while IFS= read -r proc_line; do
    [[ -n "${proc_line}" ]] || continue
    detected=1
    evidence+=("进程:${proc_line}")
  done < <(
    ps -eo pid=,args= 2>/dev/null \
      | awk '$0 ~ /(^|\/)(x-ui|3x-ui)([[:space:]]|$)/ {print $0}'
  )

  if [[ "${detected}" -eq 1 ]]; then
    local preview_count="${#evidence[@]}"
    if [[ "${preview_count}" -gt 6 ]]; then
      printf "检测到现有 3x-ui 实例，当前将以隔离模式运行。证据：%s（另有 %s 项）\n" "$(IFS='，'; echo "${evidence[*]:0:6}")" "$((preview_count - 6))"
    else
      printf "检测到现有 3x-ui 实例，当前将以隔离模式运行。证据：%s\n" "$(IFS='，'; echo "${evidence[*]}")"
    fi
    return 0
  fi

  printf "未检测到 3x-ui。\n"
  return 1
}

ps_status_external_engine_instances() {
  local label="${1}"
  local pattern="${2}"

  local found=0
  while read -r pid; do
    [[ -n "${pid}" ]] || continue
    local cmdline
    cmdline="$(ps_status_cmdline_of_pid "${pid}")"
    if ps_status_is_kprxy_pid "${pid}"; then
      continue
    fi
    found=1
    printf -- "- 检测到其他 %s 实例：PID=%s CMD=%s\n" "${label}" "${pid}" "${cmdline}"
    if [[ "${label}" == "Xray" ]]; then
      printf "  当前运行中的 Xray 似乎不属于 kprxy 管理。\n"
    fi
    if [[ "${label}" == "sing-box" ]]; then
      printf "  当前运行中的 sing-box 似乎不属于 kprxy 管理。\n"
    fi
  done < <(pgrep -f "${pattern}" 2>/dev/null || true)

  if [[ "${found}" -eq 1 ]]; then
    return 0
  fi
  return 1
}

ps_status_conflict_section() {
  ps_status_section "冲突检测"

  ps_status_detect_3xui || true

  local has_external=0
  if ps_status_external_engine_instances "Xray" 'xray'; then
    has_external=1
  fi
  if ps_status_external_engine_instances "sing-box" 'sing-box'; then
    has_external=1
  fi

  if [[ "${has_external}" -eq 0 ]]; then
    printf -- "- 未检测到 kprxy 之外的 Xray/sing-box 进程。\n"
  fi

  local service_conflict=0
  if ps_systemd_is_available; then
    if ps_systemd_service_exists xray; then
      service_conflict=1
      printf -- "- 检测到通用服务名 xray.service（可能来自其他项目）。\n"
    fi
    if ps_systemd_service_exists sing-box; then
      service_conflict=1
      printf -- "- 检测到通用服务名 sing-box.service（可能来自其他项目）。\n"
    fi
  fi
  if [[ "${service_conflict}" -eq 0 ]]; then printf -- "- 未检测到通用服务名冲突。\n"; fi

  local cfg_conflict=0
  local xcfg scfg
  xcfg="$(ps_engine_config_path xray)"
  scfg="$(ps_engine_config_path singbox)"
  if [[ "${xcfg}" == "/etc/xray/config.json" || "${scfg}" == "/etc/sing-box/config.json" ]]; then
    cfg_conflict=1
    printf -- "- 配置路径不够隔离：检测到使用通用路径。\n"
  fi
  if [[ "${cfg_conflict}" -eq 0 ]]; then printf -- "- 配置路径已隔离（%s 与 %s）。\n" "${xcfg}" "${scfg}"; fi

  local cert_conflict=0
  while IFS='|' read -r domain fullchain key; do
    [[ -n "${domain}" ]] || continue
    if [[ "${fullchain}" != ${PS_CERT_DIR}/* || "${key}" != ${PS_CERT_DIR}/* ]]; then
      cert_conflict=1
      printf -- "- 证书路径复用提醒：%s 使用了外部路径（fullchain=%s, key=%s）。\n" "${domain}" "${fullchain}" "${key}"
    fi
  done < <(jq -r '.certificates | to_entries[]? | "\(.key)|\(.value.fullchain // "")|\(.value.key // "")"' "${PS_MANIFEST}" 2>/dev/null)
  if [[ "${cert_conflict}" -eq 0 ]]; then printf -- "- 证书路径已隔离在 %s。\n" "${PS_CERT_DIR}"; fi

  local port_conflict=0
  while IFS='|' read -r scope name port; do
    [[ -n "${port}" ]] || continue
    if ! ps_port_is_listening "${port}"; then
      continue
    fi

    local owner proc pid
    owner="$(ps_port_listener_owner "${port}" || true)"
    IFS='|' read -r proc pid <<<"${owner}"

    if [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] && ps_status_is_kprxy_pid "${pid}"; then
      continue
    fi

    port_conflict=1
    printf -- "- 检测到端口冲突：%s（%s）端口 %s 已被占用，进程=%s PID=%s。\n" "${scope}" "${name}" "${port}" "${proc:-未知}" "${pid:-未知}"
  done < <(jq -r '
    [
      (.stacks[]? | "协议栈|" + (.name // .stack_id // "-") + "|" + ((.port // empty)|tostring)),
      (.inbounds[]? | "入站|" + (.tag // "-") + "|" + ((.port // empty)|tostring)),
      (.forwardings[]? | "转发监听|" + (.name // .forward_id // "-") + "|" + ((.listen_port // empty)|tostring))
    ]
    | .[]
  ' "${PS_MANIFEST}" 2>/dev/null)
  if [[ "${port_conflict}" -eq 0 ]]; then printf -- "- 未检测到端口冲突。\n"; fi
}

ps_status_summary() {
  ps_print_header "运行状态"
  ps_status_installation_section
  ps_status_engine_section
  ps_status_ports_section
  ps_status_config_section
  ps_status_apply_section
  ps_status_systemd_section
  ps_status_cert_section
  ps_status_conflict_section
}

ps_status_engine_only() {
  ps_print_header "运行状态 - 内核/进程"
  ps_status_engine_section
  ps_status_systemd_section
}

ps_status_cert_only() {
  ps_print_header "运行状态 - 证书"
  ps_status_cert_section
}

ps_status_conflict_only() {
  ps_print_header "运行状态 - 冲突检测"
  ps_status_conflict_section
}

ps_status_command() {
  local scope="${1:-summary}"
  case "${scope}" in
    summary|all|"") ps_status_summary ;;
    cert|certs) ps_status_cert_only ;;
    engine|engines|process) ps_status_engine_only ;;
    conflict|coexist|coexistence) ps_status_conflict_only ;;
    *)
      ps_log_error "不支持的 status 子项：${scope}"
      printf "可用：kprxy status [summary|engine|cert|conflict]\n"
      return 2
      ;;
  esac
}
