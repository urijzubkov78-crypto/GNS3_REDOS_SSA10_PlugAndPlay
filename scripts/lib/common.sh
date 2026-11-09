#!/usr/bin/env bash

# Shared UI and path helpers for the RED OS GNS3 kit.

if [[ -t 1 && "${NO_COLOR:-0}" != '1' ]]; then
  readonly C_RESET=$'\033[0m'
  readonly C_BOLD=$'\033[1m'
  readonly C_BLUE=$'\033[34m'
  readonly C_GREEN=$'\033[32m'
  readonly C_YELLOW=$'\033[33m'
  readonly C_RED=$'\033[31m'
else
  readonly C_RESET=''
  readonly C_BOLD=''
  readonly C_BLUE=''
  readonly C_GREEN=''
  readonly C_YELLOW=''
  readonly C_RED=''
fi

banner() {
  printf '\n%s%s%s\n' "${C_BOLD}${C_BLUE}" 'GNS3 для РЕД ОС — учебный стенд ССА10' "${C_RESET}"
  printf '%s\n\n' '────────────────────────────────────────'
}

section() {
  printf '\n%s==> %s%s\n' "${C_BOLD}${C_BLUE}" "$*" "${C_RESET}"
}

info() {
  printf '%s[INFO]%s %s\n' "${C_BLUE}" "${C_RESET}" "$*"
}

pass() {
  printf '%s[ OK ]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"
}

warn() {
  printf '%s[WARN]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2
}

error() {
  printf '%s[FAIL]%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2
}

die() {
  error "$*"
  exit 1
}

validate_profile() {
  case "$1" in
    dynamips|full) ;;
    *) die "Неизвестный профиль '$1'. Допустимо: dynamips или full." ;;
  esac
}

project_root_from_script() {
  local source_dir
  source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[1]}")" && pwd -P)"
  if [[ "$(basename -- "${source_dir}")" == 'scripts' ]]; then
    cd -- "${source_dir}/.." && pwd -P
  else
    cd -- "${source_dir}" && pwd -P
  fi
}

command_path() {
  command -v "$1" 2>/dev/null || true
}

extract_dynamips_version() {
  local output="$1"
  printf '%s\n' "${output}" \
    | sed -nE 's/.*Cisco Router Simulation Platform \(version[[:space:]]+([0-9]+(\.[0-9]+)+).*/\1/p' \
    | head -n 1
}

is_group_active() {
  id -nG 2>/dev/null | tr ' ' '\n' | grep -Fxq -- "$1"
}

tui_clear() {
  printf '\033[2J\033[H'
}

tui_cursor_off() {
  printf '\033[?25l'
}

tui_cursor_on() {
  printf '\033[?25h'
}

tui_read_key() {
  local key suffix=''
  IFS= read -rsn1 key || return 1
  if [[ "${key}" == $'\033' ]]; then
    IFS= read -rsn2 -t 0.2 suffix || true
    key+="${suffix}"
  fi
  REPLY="${key}"
}

# Arrow-key single-choice menu. Writes the selected zero-based index to the
# variable named by the first argument.
tui_select_one() {
  local -n result_ref="$1"
  local title="$2"
  shift 2
  local options=("$@")
  local cursor=0 index key

  ((${#options[@]} > 0)) || die 'Пустое меню выбора.'
  while true; do
    tui_clear
    banner
    printf '%s%s%s\n\n' "${C_BOLD}" "${title}" "${C_RESET}"
    for index in "${!options[@]}"; do
      if ((index == cursor)); then
        printf '%s> (●) %s%s\n' "${C_GREEN}" "${options[index]}" "${C_RESET}"
      else
        printf '  ( ) %s\n' "${options[index]}"
      fi
    done
    printf '\n%s\n' '↑/↓ — перемещение; Enter или пробел — выбрать; Q — выход'

    tui_read_key || die 'Ввод закрыт пользователем.'
    key="${REPLY}"
    case "${key}" in
      $'\033[A'|k|K) cursor=$(((cursor - 1 + ${#options[@]}) % ${#options[@]})) ;;
      $'\033[B'|j|J) cursor=$(((cursor + 1) % ${#options[@]})) ;;
      ''|' ') result_ref="${cursor}"; return 0 ;;
      q|Q|й|Й) die 'Мастер закрыт пользователем.' ;;
    esac
  done
}

# Arrow-key checklist. Arrays are passed by name: labels, states (0/1), locked
# (0/1). Locked entries are required and cannot be toggled.
tui_checklist() {
  local title="$1"
  local -n labels_ref="$2"
  local -n states_ref="$3"
  local -n locked_ref="$4"
  local cursor=0 index key marker prefix note=''

  ((${#labels_ref[@]} > 0)) || die 'Пустой список компонентов.'
  while true; do
    tui_clear
    banner
    printf '%s%s%s\n\n' "${C_BOLD}" "${title}" "${C_RESET}"
    for index in "${!labels_ref[@]}"; do
      prefix=' '
      ((index == cursor)) && prefix='>'
      if ((locked_ref[index])); then
        marker='●'
      elif ((states_ref[index])); then
        marker='x'
      else
        marker=' '
      fi

      if ((index == cursor)); then
        printf '%s%s [%s] %s%s\n' "${C_GREEN}" "${prefix}" "${marker}" "${labels_ref[index]}" "${C_RESET}"
      else
        printf '%s [%s] %s\n' "${prefix}" "${marker}" "${labels_ref[index]}"
      fi
    done

    printf '\n%s\n' '● — обязательный; [x] — включён; [ ] — отключён'
    printf '%s\n' '↑/↓ — перемещение; пробел — переключить; A — включить всё; Enter — продолжить; Q — выход'
    [[ -z "${note}" ]] || printf '%s%s%s\n' "${C_YELLOW}" "${note}" "${C_RESET}"
    note=''

    tui_read_key || die 'Ввод закрыт пользователем.'
    key="${REPLY}"
    case "${key}" in
      $'\033[A'|k|K) cursor=$(((cursor - 1 + ${#labels_ref[@]}) % ${#labels_ref[@]})) ;;
      $'\033[B'|j|J) cursor=$(((cursor + 1) % ${#labels_ref[@]})) ;;
      ' ')
        if ((locked_ref[cursor])); then
          note='Этот компонент обязателен для выбранного профиля.'
        else
          states_ref[cursor]=$((1 - states_ref[cursor]))
        fi
        ;;
      a|A|ф|Ф)
        for index in "${!states_ref[@]}"; do states_ref[index]=1; done
        ;;
      '') return 0 ;;
      q|Q|й|Й) die 'Мастер закрыт пользователем.' ;;
    esac
  done
}
