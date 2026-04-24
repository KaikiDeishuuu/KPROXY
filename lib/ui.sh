#!/usr/bin/env bash

if [[ -n "${PROXY_STACK_UI_SH_LOADED:-}" ]]; then
  return 0
fi
PROXY_STACK_UI_SH_LOADED=1

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=lib/logger.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logger.sh"

PS_UI_LAST_CHOICE=""

ps_ui_has_color() {
  [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]
}

ps_ui_color() {
  local code="${1:-0}"
  if ps_ui_has_color; then
    printf "\033[%sm" "${code}"
  fi
}

ps_ui_reset() {
  if ps_ui_has_color; then
    printf "\033[0m"
  fi
}

ps_ui_rule() {
  printf '%s\n' '----------------------------------------'
}

ps_ui_header() {
  local title="${1:-}"
  local cyan
  cyan="$(ps_ui_color 36)"
  local reset
  reset="$(ps_ui_reset)"

  printf "\n%s" "${cyan}"
  printf "========================================\n"
  printf " %s\n" "${title}"
  printf "========================================\n"
  printf "%s" "${reset}"
}

ps_ui_section() {
  local title="${1:-}"
  local blue
  blue="$(ps_ui_color 34)"
  local reset
  reset="$(ps_ui_reset)"
  printf "%s[%s]%s\n" "${blue}" "${title}" "${reset}"
}

ps_ui_tip() {
  local text="${1:-}"
  [[ -n "${text}" ]] || return 0
  local dim
  dim="$(ps_ui_color 2)"
  local reset
  reset="$(ps_ui_reset)"
  printf "%s%s%s\n" "${dim}" "${text}" "${reset}"
}

ps_ui_info() {
  ps_log_info "$*"
}

ps_ui_success() {
  ps_log_success "$*"
}

ps_ui_warn() {
  ps_log_warn "$*"
}

ps_ui_error() {
  ps_log_error "$*"
}

ps_ui_menu_select() {
  local title="${1}"
  local zero_label="${2:-返回}"
  local prompt="${3:-请选择}"
  shift 3
  local options=("$@")

  ps_ui_header "${title}"
  local i=1
  local option
  for option in "${options[@]}"; do
    printf " %2d. %s\n" "${i}" "${option}"
    i=$((i + 1))
  done
  printf "  0. %s\n" "${zero_label}"
  ps_ui_rule

  read -r -p "${prompt}: " PS_UI_LAST_CHOICE
}

ps_ui_menu_select_with_hint() {
  local title="${1}"
  local hint="${2:-}"
  local zero_label="${3:-返回}"
  local prompt="${4:-请选择}"
  shift 4
  local options=("$@")

  ps_ui_header "${title}"
  ps_ui_tip "${hint}"
  local i=1
  local option
  for option in "${options[@]}"; do
    printf " %2d. %s\n" "${i}" "${option}"
    i=$((i + 1))
  done
  printf "  0. %s\n" "${zero_label}"
  ps_ui_rule

  read -r -p "${prompt}: " PS_UI_LAST_CHOICE
}

ps_ui_render_table() {
  local title="${1:-列表}"
  shift || true
  local rows=("$@")

  ps_ui_section "${title}"
  if [[ "${#rows[@]}" -eq 0 ]]; then
    printf "  （空）\n"
    return 0
  fi

  local row
  for row in "${rows[@]}"; do
    printf "  - %s\n" "${row}"
  done
}
