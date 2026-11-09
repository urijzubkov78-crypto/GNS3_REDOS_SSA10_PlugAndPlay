#!/usr/bin/env bash
# Keep execution inside main so a truncated streamed download is not executed.
main() {
  set -Eeuo pipefail
  local repo_url='https://github.com/urijzubkov78-crypto/GNS3_REDOS_SSA10_PlugAndPlay.git'
  local install_dir="${GNS3_INSTALL_DIR:-${HOME}/.local/share/gns3-redos/project}"
  local bootstrap_dir="${HOME}/.local/state/gns3-redos"
  local bootstrap_log automatic=0 arg code=0
  for arg in "$@"; do
    [[ "${arg}" != '--yes' && "${arg}" != '-y' ]] || automatic=1
  done
  if ((!automatic)); then
    if ! { exec </dev/tty; } 2>/dev/null; then
      printf '[FAIL] Откройте обычный терминал: мастеру нужен ввод с клавиатуры.\n' >&2
      return 1
    fi
  fi
  ((EUID != 0)) || { printf '[FAIL] Запускайте от обычного пользователя с sudo.\n' >&2; return 1; }
  [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] \
    || { printf '[FAIL] Требуется РЕД ОС 8 x86-64.\n' >&2; return 1; }
  command -v dnf >/dev/null 2>&1 \
    || { printf '[FAIL] Не найден dnf: этот комплект рассчитан на РЕД ОС.\n' >&2; return 1; }
  local os_id os_version
  os_id="$(. /etc/os-release; printf '%s' "${ID:-}")"
  os_version="$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")"
  [[ "${os_id}" == *redos* && "${os_version}" == 8* ]] \
    || { printf '[FAIL] Требуется РЕД ОС 8.\n' >&2; return 1; }

  local old_umask
  old_umask="$(umask)"
  umask 077
  mkdir -p -- "${bootstrap_dir}"
  bootstrap_log="${bootstrap_dir}/bootstrap-$(date +%Y%m%d-%H%M%S)-$$.log"
  : > "${bootstrap_log}"
  umask "${old_umask}"
  trap 'code=$?; printf "[FAIL] Загрузчик остановился, код %s. Журнал: %s\n" "$code" "$bootstrap_log" >&2; exit "$code"' ERR
  printf '[INFO] Загрузка полного комплекта с образами (около 160 МБ).\n' | tee -a "${bootstrap_log}"
  if ! command -v git >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    command -v sudo >/dev/null 2>&1 || { printf '[FAIL] Нужен sudo.\n' >&2; return 1; }
    sudo dnf install -y git python3 2>&1 | tee -a "${bootstrap_log}"
  fi
  if [[ -d "${install_dir}/.git" ]]; then
    [[ "$(git -C "${install_dir}" remote get-url origin)" == "${repo_url}" ]] \
      || { printf '[FAIL] В выбранной папке другой репозиторий.\n' >&2; return 1; }
    git -C "${install_dir}" diff --quiet
    git -C "${install_dir}" diff --cached --quiet
    GIT_TERMINAL_PROMPT=0 git -C "${install_dir}" pull --ff-only origin main 2>&1 | tee -a "${bootstrap_log}"
  elif [[ -e "${install_dir}" ]]; then
    printf '[FAIL] Папка %s уже существует. Укажите свободный GNS3_INSTALL_DIR.\n' "${install_dir}" >&2
    return 1
  else
    mkdir -p -- "$(dirname -- "${install_dir}")"
    GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch main "${repo_url}" "${install_dir}" 2>&1 | tee -a "${bootstrap_log}"
  fi
  [[ -s "${install_dir}/setup.sh" && -s "${install_dir}/scripts/lib/logging.sh" ]] \
    || { printf '[FAIL] Комплект скачан не полностью.\n' >&2; return 1; }
  export GNS3_SOURCE_COMMIT
  GNS3_SOURCE_COMMIT="$(git -C "${install_dir}" rev-parse HEAD)"
  printf '[INFO] Комплект: %s\n[INFO] Ревизия: %s\n' "${install_dir}" "${GNS3_SOURCE_COMMIT}" | tee -a "${bootstrap_log}"
  trap - ERR
  exec bash "${install_dir}/setup.sh" "$@"
}

main "$@"
