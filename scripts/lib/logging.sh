#!/usr/bin/env bash
# Shared run lifecycle. Never record BASH_COMMAND or the process environment.

log_error() {
  local code="$1" line="$2" source_file="$3"
  printf '[FAIL] Этап: %s; файл: %s; строка: %s; код: %s\n' \
    "${GNS3_STAGE:-startup}" "${source_file##*/}" "${line}" "${code}" >&2
}

log_child_traps() {
  [[ -n "${GNS3_LOG_FILE:-}" ]] || return 0
  trap 'log_error "$?" "${LINENO}" "${BASH_SOURCE[0]:-shell}"' ERR
}

log_init() {
  local root="$1" log_python=''
  command -v python3 >/dev/null 2>&1 && log_python='python3'
  if [[ -z "${log_python}" ]] || ! "${log_python}" -c 'import sys' >/dev/null 2>&1; then
    log_python='python'
  fi
  "${log_python}" -c 'import sys; assert sys.version_info >= (3, 9)' >/dev/null 2>&1 \
    || { printf '[FAIL] Для журнала требуется Python 3.9 или новее.\n' >&2; return 1; }

  local old_umask
  old_umask="$(umask)"
  umask 077
  GNS3_LOG_DIR="${root}/logs/run-$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p -- "${GNS3_LOG_DIR}" || return 1
  GNS3_LOG_FILE="${GNS3_LOG_DIR}/install.log"
  GNS3_REPORT_FILE="${GNS3_LOG_DIR}/summary.txt"
  : > "${GNS3_LOG_FILE}" || return 1
  : > "${GNS3_REPORT_FILE}" || return 1
  umask "${old_umask}"
  export GNS3_LOG_DIR GNS3_LOG_FILE GNS3_REPORT_FILE
  GNS3_STAGE='startup'
  GNS3_RUN_STATUS='completed'
  GNS3_RUN_START=${SECONDS}
  exec 3>&1 4>&2
  exec > >("${log_python}" -u "${root}/scripts/log_filter.py" "${GNS3_LOG_FILE}" >&3 2>&4) 2>&1
  GNS3_LOG_PID=$!
  trap 'log_error "$?" "${LINENO}" "${BASH_SOURCE[0]:-shell}"' ERR
  trap 'GNS3_RUN_STATUS=interrupted; exit 130' INT
  trap 'GNS3_RUN_STATUS=interrupted; exit 143' TERM
  trap 'exit 74' PIPE
  trap 'log_finish "$?"' EXIT
  printf '[INFO] Журнал: %s\n' "${GNS3_LOG_FILE}"
}

log_finish() {
  local code="$1" logger_code=0
  trap - ERR EXIT INT TERM
  trap '' PIPE
  set +e
  if [[ -t 3 ]]; then printf '\033[?25h' >&3; fi
  if ((code != 0)) && [[ "${GNS3_RUN_STATUS}" == 'completed' ]]; then
    GNS3_RUN_STATUS='failed'
  fi
  # Closing both pipe descriptors lets the logger finish and flush its file.
  exec 1>&3 2>&4
  wait "${GNS3_LOG_PID}" || logger_code=$?
  if ((logger_code != 0)); then
    printf '[FAIL] Журнал записан не полностью (код %s).\n' "${logger_code}" >&2
    ((code != 0)) || code=74
    GNS3_RUN_STATUS='failed'
  fi
  local final_line
  printf -v final_line '[INFO] Итог: %s; код: %s; этап: %s; время: %s с.' \
    "${GNS3_RUN_STATUS}" "${code}" "${GNS3_STAGE}" "$((SECONDS - GNS3_RUN_START))"
  printf '%s\n' "${final_line}"
  printf '[%s] %s\n' "$(date +%FT%T%z)" "${final_line}" >> "${GNS3_LOG_FILE}" || code=74
  {
    printf 'status=%s\nexit_code=%s\nstage=%s\nduration_seconds=%s\n' \
      "${GNS3_RUN_STATUS}" "${code}" "${GNS3_STAGE}" "$((SECONDS - GNS3_RUN_START))"
    printf 'profile=%s\naction=%s\n' "${profile:-unknown}" "${action:-unknown}"
    printf 'source_commit=%s\n' "${GNS3_SOURCE_COMMIT:-local}"
    printf 'wireshark=%s\nvirt_tools=%s\nextra_tools=%s\n' \
      "${install_wireshark:-unknown}" "${install_virt_tools:-unknown}" "${install_extra_tools:-unknown}"
    printf 'log=install.log\n'
  } > "${GNS3_REPORT_FILE}" || code=74
  printf 'Журнал: %s\nОтчёт: %s\n' "${GNS3_LOG_FILE}" "${GNS3_REPORT_FILE}"
  exit "${code}"
}

log_stage() {
  export GNS3_STAGE="$1"
  printf '\n[STAGE] %s\n' "$2"
}
