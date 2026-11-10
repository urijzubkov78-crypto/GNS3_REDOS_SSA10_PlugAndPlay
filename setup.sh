#!/usr/bin/env bash
set -Eeuo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/common.sh
source "${project_root}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/logging.sh
source "${project_root}/scripts/lib/logging.sh"
# shellcheck source=config/lab.conf
source "${project_root}/config/lab.conf"

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

profile="${DEFAULT_PROFILE:-dynamips}"
images_dir="${project_root}/images"
action=''
assume_yes=0
full_update=0
skip_network=0
install_wireshark=1
install_virt_tools=1
install_extra_tools=1

usage() {
  cat <<'EOF'
Использование:
  ./setup.sh                         Интерактивный мастер
  ./setup.sh --all [параметры]      Полная установка
  ./setup.sh --preflight            Только предварительная проверка
  ./setup.sh --install              Только установка программ
  ./setup.sh --images               Только проверка и импорт образов
  ./setup.sh --templates            Создать и зарегистрировать шаблоны устройств
  ./setup.sh --verify               Итоговая диагностика

Параметры:
  --profile dynamips|full  dynamips: c2691+c3660; full: c2691+IOSvL2/KVM
  --images-dir DIR         Каталог с образами (по умолчанию ./images)
  --full-update            Перед установкой выполнить dnf update
  --skip-network           Не проверять доступность GitHub/PyPI
  -y, --yes                Не задавать подтверждающие вопросы
  -h, --help               Показать справку
EOF
}

# Keep --help side-effect free; all real runs, including invalid arguments, log.
if (($# == 1)) && [[ "$1" == '--help' || "$1" == '-h' ]]; then
  usage
  exit 0
fi
log_init "${project_root}"

while (($#)); do
  case "$1" in
    --all|--preflight|--install|--images|--templates|--verify)
      [[ -z "${action}" ]] || die 'Можно выбрать только одно действие.'
      action="${1#--}"
      ;;
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
    --full-update) full_update=1 ;;
    --skip-network) skip_network=1 ;;
    -y|--yes) assume_yes=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестный параметр: $1" ;;
  esac
  shift
done

validate_profile "${profile}"

interactive_menu() {
  [[ -t 0 ]] || die 'Для неинтерактивного запуска укажите действие, например --all.'
  local selected_index=0 wireshark_index=-1 virt_tools_index=-1 extra_tools_index=-1
  local profile_options=(
    'Full: c2691 + настоящий IOSvL2 через QEMU/KVM (рекомендуется)'
    'Legacy Dynamips: c2691 + c3660/NM-16ESW'
  )
  local action_options=(
    'Полная установка от проверки до итоговой диагностики'
    'Только проверить готовность системы и образов'
    'Установить программные компоненты'
    'Проверить и импортировать образы'
    'Создать и зарегистрировать шаблоны из установленных образов'
    'Проверить уже установленную систему'
  )
  local component_labels=() component_states=() component_locked=()

  tui_cursor_off >&3

  tui_select_one selected_index 'Выберите профиль стенда' "${profile_options[@]}" >&3
  case "${selected_index}" in
    0) profile='full' ;;
    1) profile='dynamips' ;;
  esac

  tui_select_one selected_index 'Выберите действие' "${action_options[@]}" >&3
  case "${selected_index}" in
    0) action='all' ;;
    1) action='preflight' ;;
    2) action='install' ;;
    3) action='images' ;;
    4) action='templates' ;;
    5) action='verify' ;;
  esac

  if [[ "${action}" == 'all' || "${action}" == 'install' ]]; then
    component_labels+=('ОБЯЗАТЕЛЬНО — GNS3 GUI/Server, Dynamips, uBridge, VPCS, Telnet/xterm')
    component_states+=(1)
    component_locked+=(1)

    if [[ "${profile}" == 'full' ]]; then
      component_labels+=('ОБЯЗАТЕЛЬНО — QEMU/KVM и libvirt для IOSvL2')
      component_states+=(1)
      component_locked+=(1)
    fi

    wireshark_index=${#component_labels[@]}
    component_labels+=('РЕКОМЕНДУЕТСЯ — Wireshark для захвата и анализа трафика')
    component_states+=(1)
    component_locked+=(0)

    if [[ "${profile}" == 'full' ]]; then
      virt_tools_index=${#component_labels[@]}
      component_labels+=('РЕКОМЕНДУЕТСЯ — virt-manager, virt-install и OVMF')
      component_states+=(1)
      component_locked+=(0)
    fi

    extra_tools_index=${#component_labels[@]}
    component_labels+=('НЕОБЯЗАТЕЛЬНО — mtools для дополнительных QEMU-операций')
    component_states+=(1)
    component_locked+=(0)

    tui_checklist 'Выберите компоненты установки' component_labels component_states component_locked >&3
    install_wireshark=${component_states[wireshark_index]}
    if ((virt_tools_index >= 0)); then
      install_virt_tools=${component_states[virt_tools_index]}
    else
      install_virt_tools=0
    fi
    install_extra_tools=${component_states[extra_tools_index]}
  fi

  tui_cursor_on >&3
  tui_clear >&3
}

[[ -n "${action}" ]] || interactive_menu
[[ "${profile}" == 'full' ]] || install_virt_tools=0

confirm() {
  local prompt="$1" answer
  ((assume_yes)) && return 0
  [[ -t 0 ]] || die "Требуется подтверждение: ${prompt}. Добавьте --yes."
  printf '%s [y/N]: ' "${prompt}" >&3
  IFS= read -r answer
  if [[ "${answer}" =~ ^[YyДд]$ ]]; then
    info 'Подтверждение получено.'
    return 0
  fi
  GNS3_RUN_STATUS='cancelled'
  info 'Действие отклонено пользователем.'
  return 1
}

run_preflight() {
  if [[ "${profile}" == 'full' && ( "${action}" == 'all' || "${action}" == 'images' ) ]]; then
    log_stage image_parts 'Подготовка комплектного образа IOSvL2'
    python3 "${project_root}/scripts/prepare_images.py" --images-dir "${images_dir}"
  fi
  log_stage preflight 'Проверка готовности системы'
  local args=(--profile "${profile}" --images-dir "${images_dir}")
  [[ "${action}" == 'all' || "${action}" == 'images' ]] && args+=(--require-images)
  ((skip_network)) && args+=(--skip-network)
  ((!install_wireshark)) && args+=(--skip-wireshark)
  ((!install_virt_tools)) && args+=(--skip-virt-tools)
  ((!install_extra_tools)) && args+=(--skip-extra-tools)
  bash "${project_root}/scripts/preflight_redos8.sh" "${args[@]}"
}

run_install() {
  log_stage programs 'Установка программных компонентов'
  local args=(--profile "${profile}")
  ((full_update)) && args+=(--full-update)
  ((!install_wireshark)) && args+=(--skip-wireshark)
  ((!install_virt_tools)) && args+=(--skip-virt-tools)
  ((!install_extra_tools)) && args+=(--skip-extra-tools)
  bash "${project_root}/scripts/install_gns3_redos8.sh" "${args[@]}"
}

find_required_image() {
  local filename="$1" found
  found="$(find "${images_dir}" -type f -name "${filename}" -print -quit 2>/dev/null || true)"
  [[ -n "${found}" ]] || return 1
  printf '%s\n' "${found}"
}

run_images() {
  log_stage images 'Проверка и установка образов'
  local router_path switch_path iosvl2_path
  local image_args=()
  router_path="$(find_required_image "${ROUTER_IMAGE}")" \
    || die "Не найден ${ROUTER_IMAGE} в ${images_dir}."
  image_args+=("${router_path}")

  if [[ "${profile}" == 'dynamips' ]]; then
    if switch_path="$(find_required_image "${SWITCH_IMAGE}")"; then
      image_args+=("${switch_path}")
    elif switch_path="$(find_required_image "${FALLBACK_SWITCH_IMAGE}")"; then
      warn "Используется резервный образ ${FALLBACK_SWITCH_IMAGE}."
      image_args+=("${switch_path}")
    else
      die "Не найден ${SWITCH_IMAGE} или ${FALLBACK_SWITCH_IMAGE}."
    fi
  else
    iosvl2_path="$(find_required_image "${IOSVL2_IMAGE}")" \
      || die "Не найден ${IOSVL2_IMAGE} в ${images_dir}."
    image_args+=("${iosvl2_path}")
  fi

  section 'Проверка образов без установки'
  bash "${project_root}/scripts/install_gns3_images.sh" --dry-run "${image_args[@]}"
  confirm 'Контрольные суммы совпали. Установить эти образы?' \
    || die 'Импорт образов отменён пользователем.'
  bash "${project_root}/scripts/install_gns3_images.sh" "${image_args[@]}"

  install -d -m 0750 "${HOME}/GNS3"
  if [[ -L "${HOME}/GNS3/images" ]]; then
    [[ "$(readlink -- "${HOME}/GNS3/images" || true)" == '/opt/gns3/images' ]] \
      || warn "Сохранена существующая ссылка ${HOME}/GNS3/images. Установленные образы находятся в /opt/gns3/images."
  elif [[ -e "${HOME}/GNS3/images" ]]; then
    warn "Сохранён существующий каталог ${HOME}/GNS3/images. Установленные образы находятся в /opt/gns3/images."
  else
    ln -s /opt/gns3/images "${HOME}/GNS3/images"
    pass "Создана ссылка ${HOME}/GNS3/images -> /opt/gns3/images."
  fi

  run_templates
}

run_templates() {
  section 'Создание и регистрация шаблонов устройств GNS3'
  log_stage templates 'Создание шаблонов устройств GNS3'
  bash "${project_root}/scripts/generate_appliances.sh" --profile "${profile}"
  log_stage template_registration 'Регистрация шаблонов в GNS3'
  python3 "${project_root}/scripts/register_appliances.py" --profile "${profile}"
}

run_verify() {
  log_stage verify 'Итоговая диагностика'
  local args=(--images-dir /opt/gns3/images)
  [[ "${profile}" == 'dynamips' ]] && args+=(--dynamips-only)
  bash "${project_root}/scripts/check_gns3_redos8.sh" "${args[@]}"
}

banner
info "Действие: ${action}"
info "Профиль: ${profile}"
info "Wireshark: $([[ ${install_wireshark} -eq 1 ]] && printf 'включён' || printf 'пропущен')"
info "Средства виртуализации: $([[ ${install_virt_tools} -eq 1 ]] && printf 'включены' || printf 'пропущены')"
info "Дополнительные утилиты: $([[ ${install_extra_tools} -eq 1 ]] && printf 'включены' || printf 'пропущены')"
info "Ревизия: ${GNS3_SOURCE_COMMIT:-local}"

case "${action}" in
  preflight)
    run_preflight
    ;;
  install)
    run_preflight
    confirm 'Начать установку системных компонентов?' || die 'Установка отменена.'
    run_install
    ;;
  images)
    run_preflight
    run_images
    ;;
  templates)
    run_templates
    ;;
  verify)
    run_verify
    ;;
  all)
    run_preflight
    confirm 'Все предварительные проверки пройдены. Начать полную установку?' \
      || die 'Установка отменена.'
    run_install
    run_images
    section 'Проверка после установки'
    if run_verify; then
      pass 'Основные проверки завершились успешно.'
    else
      warn 'Диагностика выявила ошибки. Если группы ещё не применились, войдите в сеанс заново и повторите проверку.'
      exit 1
    fi
    ;;
esac

section 'Готово'
info "Полный журнал сохранён: ${GNS3_LOG_FILE}"
if [[ "${action}" == 'all' || "${action}" == 'install' ]]; then
  printf '%s\n' 'Перезагрузите рабочую станцию или заново войдите в сеанс, затем выполните:'
  printf '  bash %q --profile %q --verify\n' "${project_root}/setup.sh" "${profile}"
fi
