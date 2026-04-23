#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_CERT_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_CERT_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"
# shellcheck source=lib/stack.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stack.sh"

ps_cert_acme_bin() {
  if ps_command_exists acme.sh; then
    command -v acme.sh
    return 0
  fi
  if [[ -x "${HOME}/.acme.sh/acme.sh" ]]; then
    printf "%s" "${HOME}/.acme.sh/acme.sh"
    return 0
  fi
  return 1
}

ps_cert_ensure_acme() {
  if ps_cert_acme_bin >/dev/null 2>&1; then
    return 0
  fi

  ps_log_info "acme.sh not found, installing..."
  local email
  email="$(ps_prompt_required "Email for ACME registration")"
  if ! curl -fsSL https://get.acme.sh | sh -s email="${email}"; then
    ps_log_error "Failed to install acme.sh"
    return 1
  fi

  if ! ps_cert_acme_bin >/dev/null 2>&1; then
    ps_log_error "acme.sh installed but command not found"
    return 1
  fi
}

ps_cert_list() {
  ps_print_header "Certificates"
  jq -r '
    if (.certificates | length) == 0 then
      "No certificates configured."
    else
      (.certificates | to_entries[] |
        "- \(.key) issuer=\(.value.issuer // "-") fullchain=\(.value.fullchain // "-") key=\(.value.key // "-") renew_mode=\(.value.renew_mode // "-") renew_enabled=\(.value.renew_enabled // false)")
    end
  ' "${PS_MANIFEST}"
}

ps_cert_issue_acme() {
  ps_print_header "Issue Certificate (ACME)"
  ps_cert_ensure_acme || return 1

  local mode domain webroot_dir
  printf "1) standalone\n2) webroot\n3) cloudflare\n"
  case "$(ps_prompt_required "Mode number")" in
    1) mode="standalone" ;;
    2) mode="webroot" ;;
    3) mode="cloudflare" ;;
    *) ps_log_error "Invalid mode"; return 1 ;;
  esac

  domain="$(ps_prompt_required "Domain")"
  local acme_bin
  acme_bin="$(ps_cert_acme_bin)"

  local issue_cmd=()
  case "${mode}" in
    standalone)
      issue_cmd=("${acme_bin}" --issue -d "${domain}" --standalone)
      ;;
    webroot)
      webroot_dir="$(ps_prompt_required "Webroot directory")"
      issue_cmd=("${acme_bin}" --issue -d "${domain}" -w "${webroot_dir}")
      ;;
    cloudflare)
      local cf_token cf_account
      cf_token="$(ps_prompt_required "Cloudflare API Token")"
      cf_account="$(ps_prompt_required "Cloudflare Account ID")"
      export CF_Token="${cf_token}"
      export CF_Account_ID="${cf_account}"
      issue_cmd=("${acme_bin}" --issue -d "${domain}" --dns dns_cf)
      ;;
  esac

  if ! "${issue_cmd[@]}"; then
    ps_log_error "Certificate issue failed for ${domain}"
    return 1
  fi

  local cert_dir="${PS_CERT_DIR}/${domain}"
  mkdir -p "${cert_dir}"
  local key_path="${cert_dir}/key.pem"
  local fullchain_path="${cert_dir}/fullchain.pem"

  if ! "${acme_bin}" --install-cert -d "${domain}" --key-file "${key_path}" --fullchain-file "${fullchain_path}"; then
    ps_log_error "Certificate install failed for ${domain}"
    return 1
  fi

  ps_manifest_update \
    --arg domain "${domain}" \
    --arg fullchain "${fullchain_path}" \
    --arg key "${key_path}" \
    --arg issuer "acme.sh" \
    --arg renew_mode "${mode}" \
    --argjson renew_enabled true \
    --arg updated "$(ps_now_iso)" \
    '.certificates[$domain] = {domain:$domain, fullchain:$fullchain, key:$key, issuer:$issuer, renew_mode:$renew_mode, renew_enabled:$renew_enabled, updated_at:$updated} | .meta.updated_at = $updated'

  ps_log_success "Certificate issued and installed: ${domain}"
}

ps_cert_install_custom() {
  ps_print_header "Install Custom Certificate"
  local domain fullchain_path key_path
  domain="$(ps_prompt_required "Domain")"
  fullchain_path="$(ps_prompt_required "Fullchain path")"
  key_path="$(ps_prompt_required "Private key path")"

  if [[ ! -f "${fullchain_path}" || ! -f "${key_path}" ]]; then
    ps_log_error "Certificate file not found"
    return 1
  fi

  local cert_dir="${PS_CERT_DIR}/${domain}"
  mkdir -p "${cert_dir}"
  cp -a "${fullchain_path}" "${cert_dir}/fullchain.pem"
  cp -a "${key_path}" "${cert_dir}/key.pem"

  ps_manifest_update \
    --arg domain "${domain}" \
    --arg fullchain "${cert_dir}/fullchain.pem" \
    --arg key "${cert_dir}/key.pem" \
    --arg issuer "manual" \
    --arg renew_mode "manual" \
    --argjson renew_enabled false \
    --arg updated "$(ps_now_iso)" \
    '.certificates[$domain] = {domain:$domain, fullchain:$fullchain, key:$key, issuer:$issuer, renew_mode:$renew_mode, renew_enabled:$renew_enabled, updated_at:$updated} | .meta.updated_at = $updated'

  ps_log_success "Custom certificate installed: ${domain}"
}

ps_cert_configure_auto_renew() {
  ps_print_header "Configure Auto Renewal"
  local domain
  domain="$(ps_prompt_required "Domain")"

  if [[ "$(jq -r --arg d "${domain}" '.certificates[$d] | type' "${PS_MANIFEST}")" == "null" ]]; then
    ps_log_error "Domain not found in manifest: ${domain}"
    return 1
  fi

  local mode enabled
  mode="$(ps_prompt "Renew mode (standalone/webroot/cloudflare/manual)" "standalone")"
  enabled="$(ps_prompt "Enable renew (true/false)" "true")"

  ps_manifest_update \
    --arg domain "${domain}" \
    --arg mode "${mode}" \
    --argjson enabled "${enabled}" \
    --arg updated "$(ps_now_iso)" \
    '.certificates[$domain].renew_mode = $mode | .certificates[$domain].renew_enabled = $enabled | .certificates[$domain].updated_at = $updated | .meta.updated_at = $updated'

  if [[ "${enabled}" == "true" ]]; then
    local cron_line="17 3 * * * root ${HOME}/.acme.sh/acme.sh --cron --home ${HOME}/.acme.sh >/dev/null 2>&1 && (systemctl reload ${PS_XRAY_SERVICE} ${PS_SINGBOX_SERVICE} >/dev/null 2>&1 || true)"
    if ps_is_root; then
      printf "%s\n" "${cron_line}" > /etc/cron.d/proxy-stack-acme
      ps_log_info "Renewal cron written: /etc/cron.d/proxy-stack-acme"
    else
      local renew_script="${PS_ROOT_DIR}/.runtime/renew-acme.sh"
      mkdir -p "$(dirname "${renew_script}")"
      cat >"${renew_script}" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
"${HOME}/.acme.sh/acme.sh" --cron --home "${HOME}/.acme.sh"
SCRIPT
      chmod +x "${renew_script}"
      ps_log_warn "Non-root mode: create your own cron entry for ${renew_script}"
    fi
  fi

  ps_log_success "Renewal setting updated for ${domain}"
}

ps_cert_test_renewal() {
  ps_print_header "Test Renewal"
  local acme_bin
  acme_bin="$(ps_cert_acme_bin || true)"
  if [[ -z "${acme_bin}" ]]; then
    ps_log_error "acme.sh not found"
    return 1
  fi

  if "${acme_bin}" --cron --force; then
    ps_log_success "Renewal test completed"
  else
    ps_log_error "Renewal test failed"
    return 1
  fi
}

ps_cert_manage_reality_params() {
  ps_print_header "Manage SNI / REALITY Params"
  local stack_id
  stack_id="$(ps_stack_pick_id)" || return 1

  local sni dest fingerprint short_id public_key private_key
  sni="$(ps_prompt "SNI" "")"
  dest="$(ps_prompt "Dest host:port" "")"
  fingerprint="$(ps_prompt "Fingerprint" "chrome")"
  short_id="$(ps_prompt "Short ID" "")"
  public_key="$(ps_prompt "REALITY public key (optional)" "")"
  private_key="$(ps_prompt "REALITY private key (optional)" "")"

  local jq_filter='.stacks |= map(if .stack_id == $id then . else . end)'
  [[ -n "${sni}" ]] && jq_filter+=' | .stacks |= map(if .stack_id == $id then .reality.server_name = $sni else . end)'
  [[ -n "${dest}" ]] && jq_filter+=' | .stacks |= map(if .stack_id == $id then .reality.dest = $dest else . end)'
  [[ -n "${fingerprint}" ]] && jq_filter+=' | .stacks |= map(if .stack_id == $id then .reality.fingerprint = $fingerprint else . end)'
  [[ -n "${short_id}" ]] && jq_filter+=' | .stacks |= map(if .stack_id == $id then .reality.short_id = $short_id else . end)'
  [[ -n "${public_key}" ]] && jq_filter+=' | .stacks |= map(if .stack_id == $id then .reality.public_key = $public_key else . end)'
  [[ -n "${private_key}" ]] && jq_filter+=' | .stacks |= map(if .stack_id == $id then .reality.private_key = $private_key else . end)'
  jq_filter+=' | .stacks |= map(if .stack_id == $id then .updated_at = $ts else . end) | .meta.updated_at = $ts'

  ps_manifest_update \
    --arg id "${stack_id}" \
    --arg sni "${sni}" \
    --arg dest "${dest}" \
    --arg fingerprint "${fingerprint}" \
    --arg short_id "${short_id}" \
    --arg public_key "${public_key}" \
    --arg private_key "${private_key}" \
    --arg ts "$(ps_now_iso)" \
    "${jq_filter}"

  ps_log_success "REALITY handshake parameters updated: ${stack_id}"
}
