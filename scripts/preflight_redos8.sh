#!/usr/bin/env bash
set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"
project_root="$(cd -- "${script_dir}/.." && pwd -P)"
# shellcheck source=../config/lab.conf
source "${project_root}/config/lab.conf"

profile="${DEFAULT_PROFILE:-dynamips}"
images_dir="${project_root}/images"
require_images=0
skip_network=0
failures=0
warnings=0
check_wireshark=1
check_virt_tools=1
check_extra_tools=1

usage() {
  cat <<'EOF'
Использование:
  ./scripts/preflight_redos8.sh [параметры]

Параметры:
  --profile dynamips|full  Проверяемый профиль (по умолчанию dynamips).
  --images-dir DIR         Каталог с IOS/QEMU-образами.
  --require-images         Считать отсутствие образов критической ошибкой.
  --skip-network           Не проверять доступ к GitHub и PyPI.
  --skip-wireshark         Не проверять рекомендуемый Wireshark.
  --skip-virt-tools        Не проверять дополнительные средства виртуализации.
  --skip-extra-tools       Не проверять дополнительные утилиты.
  --minimal                Проверить только обязательные компоненты.
  -h, --help               Показать справку.
EOF
}

ok() { pass "$*"; }
bad() { error "$*"; failures=$((failures + 1)); }
note() { warn "$*"; warnings=$((warnings + 1)); }

while (($#)); do
  case "$1" in
    --profile)
      (($# >= 2)) || die 'После --profile требуется значение.'
      profile="$2"
      shift
      ;;
    --images-dir)
      (($# >= 2)) || die 'После --images-dir требуется путь.'
      images_dir="$2"
      shift
      ;;
    --require-images) require_images=1 ;;
    --skip-network) skip_network=1 ;;
    --skip-wireshark) check_wireshark=0 ;;
    --skip-virt-tools) check_virt_tools=0 ;;
    --skip-extra-tools) check_extra_tools=0 ;;
    --minimal)
      check_wireshark=0
      check_virt_tools=0
      check_extra_tools=0
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестный параметр: $1" ;;
  esac
  shift
done

validate_profile "${profile}"
banner
section 'Предварительная проверка'
info "Профиль: ${profile}"
info "Каталог образов: ${images_dir}"

if [[ "${profile}" == 'full' ]]; then
  if command -v python3 >/dev/null 2>&1; then
    if ! python3 "${project_root}/scripts/prepare_images.py" --images-dir "${images_dir}"; then
      bad 'Сборка или проверка частей IOSvL2 завершилась ошибкой.'
    fi
  else
    note 'Для сборки комплектного образа IOSvL2 потребуется Python 3.'
  fi
fi

if ((EUID == 0)); then
  bad 'Запуск от root запрещён; используйте обычного пользователя с sudo.'
else
  ok "Запуск от пользователя ${USER:-$(id -un)}."
fi

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" == *redos* || "${NAME:-}" == *'RED OS'* || "${NAME:-}" == *'РЕД ОС'* ]]; then
    ok "Обнаружена ${PRETTY_NAME:-РЕД ОС}."
    if [[ "${VERSION_ID:-}" != 8* ]]; then
      bad "Комплект проверен для РЕД ОС 8, обнаружена версия ${VERSION_ID:-неизвестна}."
    fi
  else
    bad "Обнаружена ${PRETTY_NAME:-неизвестная ОС}; требуется РЕД ОС 8."
  fi
else
  bad 'Файл /etc/os-release недоступен.'
fi

arch="$(uname -m 2>/dev/null || true)"
[[ "${arch}" == 'x86_64' ]] && ok 'Архитектура x86_64.' || bad "Неподдерживаемая архитектура: ${arch:-неизвестна}."

for command_name in sudo dnf rpm getent awk grep sed find; do
  command -v "${command_name}" >/dev/null 2>&1 \
    && ok "Команда ${command_name} доступна." \
    || bad "Не найдена обязательная команда ${command_name}."
done

if command -v sudo >/dev/null 2>&1; then
  if sudo -n true 2>/dev/null; then
    ok 'sudo готов к работе без повторного запроса пароля.'
  else
    note 'sudo запросит пароль администратора во время установки.'
  fi
fi

cpu_threads="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '0')"
ram_mib="$(awk '/MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null || printf '0')"
disk_kib="$(df -Pk "${project_root}" 2>/dev/null | awk 'NR==2 {print $4}')"
disk_gib="$(( ${disk_kib:-0} / 1024 / 1024 ))"

((cpu_threads >= 8)) && ok "Потоков CPU: ${cpu_threads}." || bad "Требуется минимум 8 потоков CPU, найдено ${cpu_threads}."
((ram_mib >= 15000)) && ok "ОЗУ: ${ram_mib} МиБ." || bad "Требуется 16 ГБ ОЗУ, найдено ${ram_mib} МиБ."
((disk_gib >= 50)) && ok "Свободно на диске: ${disk_gib} ГиБ." || bad "Требуется не менее 50 ГиБ, свободно ${disk_gib} ГиБ."

if [[ "${profile}" == 'full' ]]; then
  if grep -Eq '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
    ok 'VT-x/AMD-V доступна процессору.'
  else
    bad 'Для профиля full не обнаружена VT-x/AMD-V; проверьте BIOS/UEFI.'
  fi
else
  ok 'Профиль dynamips не требует KVM.'
fi

package_known() {
  local package_name="$1"
  rpm -q --quiet "${package_name}" 2>/dev/null && return 0
  dnf -q list --available "${package_name}" >/dev/null 2>&1
}

section 'Пакеты в подключённых репозиториях'
base_packages=(
  git gcc gcc-c++ make cmake elfutils-libelf-devel libpcap-devel libcap
  python3 python3-pip python3-devel pipx curl tar unzip xterm
)
full_packages=(
  libvirt qemu-kvm boost-random boost-program-options boost-regex
)
virt_tool_packages=(virt-install virt-manager openssh-askpass OVMF)

packages=("${base_packages[@]}")
[[ "${profile}" == 'full' ]] && packages+=("${full_packages[@]}")

if command -v dnf >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1; then
  for package_name in "${packages[@]}"; do
    if package_known "${package_name}"; then
      ok "Пакет доступен: ${package_name}."
    elif [[ "${package_name}" == 'pipx' ]]; then
      note 'Пакет pipx не найден; установщик попробует python3 -m pip install --user pipx.'
    else
      bad "Пакет отсутствует в подключённых репозиториях: ${package_name}."
    fi
  done

  if ((check_wireshark)); then
    if package_known wireshark || package_known wireshark-qt; then
      ok 'Рекомендуемый Wireshark доступен.'
    else
      note 'Не найден рекомендуемый пакет wireshark/wireshark-qt.'
    fi
  fi

  if package_known telnet || package_known inetutils; then
    ok 'Telnet-клиент доступен.'
  else
    bad 'Не найден обязательный пакет telnet/inetutils для консоли GNS3.'
  fi

  if [[ "${profile}" == 'full' ]] && ((check_virt_tools)); then
    for package_name in "${virt_tool_packages[@]}"; do
      package_known "${package_name}" \
        && ok "Рекомендуемый пакет доступен: ${package_name}." \
        || note "Не найден рекомендуемый пакет: ${package_name}."
    done
  fi

  if ((check_extra_tools)); then
    package_known mtools \
      && ok 'Дополнительный пакет доступен: mtools.' \
      || note 'Не найден дополнительный пакет mtools.'
  fi
fi

if ((skip_network)); then
  note 'Проверка сети пропущена параметром --skip-network.'
else
  section 'Доступ к источникам установки'
  if command -v curl >/dev/null 2>&1; then
    for url in https://github.com/GNS3 https://pypi.org/simple/gns3-server/; do
      if curl -fsIL --max-time 15 "${url}" >/dev/null 2>&1; then
        ok "Доступен ${url}"
      else
        bad "Нет доступа к ${url}"
      fi
    done
  else
    note 'curl ещё не установлен; проверка сети будет повторена установщиком.'
  fi
fi

find_image() {
  local filename="$1"
  [[ -d "${images_dir}" ]] || return 1
  find "${images_dir}" -type f -name "${filename}" -print -quit 2>/dev/null | grep -q .
}

check_image_with_md5() {
  local filename="$1" image_path md5_path
  image_path="$(find "${images_dir}" -type f -name "${filename}" -print -quit 2>/dev/null || true)"
  if [[ -z "${image_path}" ]]; then
    if ((require_images)); then bad "Не найден образ ${filename}."; else note "Пока не найден образ ${filename}."; fi
    return
  fi
  ok "Найден образ: ${image_path}"
  for md5_path in "${image_path}.md5" "${image_path%.*}.md5"; do
    if [[ -f "${md5_path}" ]]; then
      ok "Найдена контрольная сумма: ${md5_path}"
      return
    fi
  done
  if ((require_images)); then bad "Для ${filename} нет соседнего .md5."; else note "Для ${filename} нет соседнего .md5."; fi
}

section 'Образы лабораторного стенда'
check_image_with_md5 "${ROUTER_IMAGE}"
if [[ "${profile}" == 'dynamips' ]]; then
  if find_image "${SWITCH_IMAGE}"; then
    check_image_with_md5 "${SWITCH_IMAGE}"
  else
    note "Основной образ ${SWITCH_IMAGE} не найден; проверяю резервный."
    check_image_with_md5 "${FALLBACK_SWITCH_IMAGE}"
  fi
else
  check_image_with_md5 "${IOSVL2_IMAGE}"
fi

section 'Результат'
printf 'Ошибок: %d; предупреждений: %d\n' "${failures}" "${warnings}"
((failures == 0))
