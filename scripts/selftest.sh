#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_root="$(cd -- "${script_dir}/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"
# shellcheck source=../config/lab.conf
source "${project_root}/config/lab.conf"

failures=0

test_pass() { pass "$*"; }
test_fail() { error "$*"; failures=$((failures + 1)); }

banner
section 'Проверка структуры проекта'
required_paths=(
  "${project_root}/setup.sh"
  "${project_root}/config/lab.conf"
  "${project_root}/images/IOS"
  "${project_root}/images/QEMU"
  "${project_root}/logs"
  "${script_dir}/preflight_redos8.sh"
  "${script_dir}/install_gns3_redos8.sh"
  "${script_dir}/install_gns3_images.sh"
  "${script_dir}/generate_appliances.sh"
  "${script_dir}/check_gns3_redos8.sh"
)

for required_path in "${required_paths[@]}"; do
  [[ -e "${required_path}" ]] \
    && test_pass "Есть ${required_path#${project_root}/}" \
    || test_fail "Отсутствует ${required_path#${project_root}/}"
done

section 'Синтаксис Bash'
scripts=(
  "${project_root}/setup.sh"
  "${project_root}/bootstrap.sh"
  "${script_dir}/preflight_redos8.sh"
  "${script_dir}/install_gns3_redos8.sh"
  "${script_dir}/install_gns3_images.sh"
  "${script_dir}/generate_appliances.sh"
  "${script_dir}/check_gns3_redos8.sh"
  "${script_dir}/selftest.sh"
  "${script_dir}/lib/common.sh"
  "${script_dir}/lib/logging.sh"
)

for script_path in "${scripts[@]}"; do
  if bash -n "${script_path}"; then
    test_pass "bash -n: ${script_path#${project_root}/}"
  else
    test_fail "Ошибка синтаксиса: ${script_path#${project_root}/}"
  fi
done

section 'Интерфейсы командной строки'
help_commands=(
  "bash '${project_root}/setup.sh' --help"
  "bash '${script_dir}/preflight_redos8.sh' --help"
  "bash '${script_dir}/install_gns3_redos8.sh' --help"
  "bash '${script_dir}/install_gns3_images.sh' --help"
  "bash '${script_dir}/generate_appliances.sh' --help"
  "bash '${script_dir}/check_gns3_redos8.sh' --help"
)

for help_command in "${help_commands[@]}"; do
  if eval "${help_command}" >/dev/null; then
    test_pass "Справка работает: ${help_command}"
  else
    test_fail "Справка завершилась ошибкой: ${help_command}"
  fi
done

if [[ "${DEFAULT_PROFILE}" == 'full' ]]; then
  test_pass 'По умолчанию выбран профиль full с IOSvL2.'
else
  test_fail "Неожиданный профиль по умолчанию: ${DEFAULT_PROFILE}."
fi

if declare -F tui_select_one >/dev/null \
  && declare -F tui_checklist >/dev/null \
  && grep -q -- 'tui_checklist' "${project_root}/setup.sh"; then
  test_pass 'Консольное меню выбора и чекбоксы подключены к мастеру.'
else
  test_fail 'Консольное меню выбора компонентов не подключено.'
fi

if printf '\033[B \n' | NO_COLOR=1 bash -c '
  source "$1"
  labels=("обязательный" "рекомендуемый")
  states=(1 1)
  locked=(1 0)
  tui_checklist "Тест чекбокса" labels states locked >/dev/null
  [[ ${states[0]} -eq 1 && ${states[1]} -eq 0 ]]
' _ "${script_dir}/lib/common.sh"; then
  test_pass 'Пробел переключает выбранный чекбокс, обязательный пункт остаётся включён.'
else
  test_fail 'Проверка управления чекбоксами клавишей Пробел завершилась ошибкой.'
fi

if bash "${project_root}/setup.sh" --help | grep -Eq -- '--minimal|--skip-wireshark|--skip-virt-tools|--skip-extra-tools'; then
  test_fail 'Во внешнем интерфейсе setup.sh остались флаги ручного выбора компонентов.'
else
  test_pass 'Выбор компонентов выполняется через TUI, без пользовательских флагов.'
fi

dynamips_sample=$'Invalid platform type '\''none'\''\nCisco Router Simulation Platform (version 0.2.25-amd64/Linux stable)'
if [[ "$(extract_dynamips_version "${dynamips_sample}")" == '0.2.25' ]]; then
  test_pass 'Версия Dynamips извлекается из полного вывода, даже если первая строка содержит диагностическое сообщение.'
else
  test_fail 'Не удалось извлечь версию Dynamips из его штатного вывода.'
fi

section 'Безопасная проверка импорта образа'
temp_dir="$(mktemp -d -t gns3-kit-selftest.XXXXXX)"
cleanup() {
  case "${temp_dir}" in
    */gns3-kit-selftest.*) rm -rf -- "${temp_dir}" ;;
  esac
}
trap cleanup EXIT

fixture="${temp_dir}/selftest-ios.bin"
printf '%s\n' 'GNS3 kit checksum self-test fixture' > "${fixture}"
md5sum "${fixture}" | awk '{print $1}' > "${temp_dir}/selftest-ios.md5"

if bash "${script_dir}/install_gns3_images.sh" --dry-run "${fixture}" >/dev/null; then
  test_pass 'Корректный соседний .md5 принимается.'
else
  test_fail 'Корректный соседний .md5 был отклонён.'
fi

rootless_images="${temp_dir}/rootless-images"
if GNS3_IMAGES_ROOT="${rootless_images}" \
    bash "${script_dir}/install_gns3_images.sh" "${fixture}" >/dev/null \
  && [[ -s "${rootless_images}/IOS/$(basename -- "${fixture}")" ]] \
  && [[ -s "${rootless_images}/SHA256SUMS" ]] \
  && (cd "${rootless_images}" && sha256sum -c SHA256SUMS >/dev/null); then
  test_pass 'Тестовый образ реально копируется, повторно читается и проходит SHA-256.'
else
  test_fail 'Интеграционная проверка фактического копирования образа завершилась ошибкой.'
fi

section 'Генерация шаблонов appliances'
fake_images="${temp_dir}/installed-images"
fake_output="${temp_dir}/appliances"
python_for_test='python3'
if ! python3 -c 'import sys' >/dev/null 2>&1; then
  python_for_test='python'
fi
mkdir -p -- "${fake_images}/IOS" "${fake_images}/QEMU" "${fake_output}"
printf '%s\n' 'router image fixture' > "${fake_images}/IOS/${ROUTER_IMAGE%.bin}.image"
printf '%s\n' 'switch image fixture' > "${fake_images}/IOS/${SWITCH_IMAGE%.bin}.image"

if PYTHON_BIN="${python_for_test}" bash "${script_dir}/generate_appliances.sh" \
    --profile dynamips \
    --images-root "${fake_images}" \
    --output-dir "${fake_output}" \
    --no-user-copy >/dev/null; then
  test_pass 'Генератор шаблонов завершился успешно.'
else
  test_fail 'Генератор шаблонов завершился ошибкой.'
fi

generated_templates=(
  "${fake_output}/ssa10-c2691-router.gns3a"
  "${fake_output}/ssa10-c2691-isp.gns3a"
  "${fake_output}/ssa10-etherswitch.gns3a"
)
for template_path in "${generated_templates[@]}"; do
  [[ -s "${template_path}" ]] \
    && test_pass "Создан ${template_path#${temp_dir}/}" \
    || test_fail "Не создан ${template_path#${temp_dir}/}"
done

if "${python_for_test}" - "${generated_templates[@]}" <<'PY'
import json
import sys

for filename in sys.argv[1:]:
    with open(filename, encoding="utf-8") as stream:
        appliance = json.load(stream)
    assert appliance["registry_version"] == 4
    assert len(appliance["appliance_id"]) == 36
    assert appliance["images"][0]["filesize"] > 0
    assert len(appliance["images"][0]["md5sum"]) == 32

switch = json.load(open(sys.argv[-1], encoding="utf-8"))
assert switch["dynamips"]["platform"] == "c3600"
assert switch["dynamips"]["chassis"] == "3660"
assert switch["dynamips"]["slot1"] == "NM-16ESW"
PY
then
  test_pass 'JSON и ключевые параметры созданных шаблонов корректны.'
else
  test_fail 'Созданные шаблоны не прошли проверку JSON или параметров.'
fi

fake_output_full="${temp_dir}/appliances-full"
mkdir -p -- "${fake_output_full}"
rm -f -- "${fake_images}/IOS/${ROUTER_IMAGE%.bin}.image"
printf '%s\n' 'router bin image fixture' > "${fake_images}/IOS/${ROUTER_IMAGE}"
printf '%s\n' 'iosvl2 image fixture' > "${fake_images}/QEMU/${IOSVL2_IMAGE}"
if PYTHON_BIN="${python_for_test}" bash "${script_dir}/generate_appliances.sh" \
    --profile full \
    --images-root "${fake_images}" \
    --output-dir "${fake_output_full}" \
    --no-user-copy >/dev/null \
  && "${python_for_test}" - "${fake_output_full}/ssa10-iosvl2.gns3a" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    appliance = json.load(stream)
assert appliance["category"] == "multilayer_switch"
assert appliance["qemu"]["adapter_type"] == "e1000"
assert appliance["qemu"]["adapters"] == 16
assert appliance["qemu"]["ram"] == 768
assert appliance["qemu"]["kvm"] == "require"
PY
then
  test_pass 'Профиль full создаёт корректный шаблон IOSvL2.'
else
  test_fail 'Шаблон IOSvL2 профиля full не прошёл проверку.'
fi

printf '%032d\n' 0 > "${temp_dir}/selftest-ios.md5"
if bash "${script_dir}/install_gns3_images.sh" --dry-run "${fixture}" >/dev/null 2>&1; then
  test_fail 'Неверная контрольная сумма не была отклонена.'
else
  test_pass 'Неверная контрольная сумма отклоняется.'
fi

if command -v shellcheck >/dev/null 2>&1; then
  section 'ShellCheck'
  if shellcheck -x -P SCRIPTDIR "${scripts[@]}"; then
    test_pass 'ShellCheck не нашёл ошибок.'
  else
    test_fail 'ShellCheck нашёл ошибки.'
  fi
else
  warn 'ShellCheck не установлен; статический анализ пропущен.'
fi

section 'Итог самотестирования'
printf 'Ошибок: %d\n' "${failures}"
((failures == 0))
