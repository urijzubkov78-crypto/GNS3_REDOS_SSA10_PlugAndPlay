#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_root="$(cd -- "${script_dir}/.." && pwd -P)"
# shellcheck source=../config/lab.conf
source "${project_root}/config/lab.conf"
# shellcheck source=lib/logging.sh
source "${script_dir}/lib/logging.sh"
log_child_traps

profile="${DEFAULT_PROFILE:-dynamips}"
images_root='/opt/gns3/images'
output_dir="${project_root}/generated/appliances"
copy_to_user=1
python_bin="${PYTHON_BIN:-python3}"

usage() {
  cat <<'EOF'
Использование:
  ./scripts/generate_appliances.sh [--profile dynamips|full] [параметры]

Создаёт .gns3a-шаблоны с фактическими именами, размерами и MD5 установленных
образов, затем копирует их в ~/GNS3/appliances.

Параметры для проверки и нестандартного размещения:
  --images-root DIR  Корень установленных образов (по умолчанию /opt/gns3/images).
  --output-dir DIR   Каталог создаваемых шаблонов.
  --no-user-copy     Не копировать шаблоны в ~/GNS3/appliances.
EOF
}

while (($#)); do
  case "$1" in
    --profile)
      (($# >= 2)) || { printf '[ERROR] --profile requires a value\n' >&2; exit 2; }
      profile="$2"
      shift
      ;;
    --images-root)
      (($# >= 2)) || { printf '[ERROR] --images-root requires a value\n' >&2; exit 2; }
      images_root="$2"
      shift
      ;;
    --output-dir)
      (($# >= 2)) || { printf '[ERROR] --output-dir requires a value\n' >&2; exit 2; }
      output_dir="$2"
      shift
      ;;
    --no-user-copy) copy_to_user=0 ;;
    -h|--help) usage; exit 0 ;;
    *) printf '[ERROR] Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

case "${profile}" in
  dynamips|full) ;;
  *) printf '[ERROR] Unknown profile: %s\n' "${profile}" >&2; exit 2 ;;
esac

resolve_installed_ios() {
  local source_name="$1"
  local image_name="${source_name%.bin}.image"
  if [[ -r "${images_root}/IOS/${image_name}" ]]; then
    printf '%s\n' "${images_root}/IOS/${image_name}"
  elif [[ -r "${images_root}/IOS/${source_name}" ]]; then
    printf '%s\n' "${images_root}/IOS/${source_name}"
  elif command -v sudo >/dev/null 2>&1 \
      && sudo test -r "${images_root}/IOS/${source_name}"; then
    printf '%s\n' "${images_root}/IOS/${source_name}"
  elif command -v sudo >/dev/null 2>&1 \
      && sudo test -r "${images_root}/IOS/${image_name}"; then
    printf '%s\n' "${images_root}/IOS/${image_name}"
  else
    return 1
  fi
}

is_readable() {
  local path="$1"
  [[ -r "${path}" ]] && return 0
  command -v sudo >/dev/null 2>&1 && sudo test -r "${path}"
}

file_md5() {
  local path="$1"
  if [[ -r "${path}" ]]; then md5sum -- "${path}"; else sudo md5sum -- "${path}"; fi
}

file_size() {
  local path="$1"
  if [[ -r "${path}" ]]; then stat -c '%s' -- "${path}"; else sudo stat -c '%s' -- "${path}"; fi
}

router_path="$(resolve_installed_ios "${ROUTER_IMAGE}")" \
  || {
    printf '[ERROR] Router image is not available. Checked:\n' >&2
    printf '  %s/IOS/%s\n' "${images_root}" "${ROUTER_IMAGE%.bin}.image" >&2
    printf '  %s/IOS/%s\n' "${images_root}" "${ROUTER_IMAGE}" >&2
    printf '[HINT] Import the images first: bash setup.sh --profile %s --images\n' "${profile}" >&2
    exit 1
  }

switch_path=''
if [[ "${profile}" == 'dynamips' ]]; then
  if ! switch_path="$(resolve_installed_ios "${SWITCH_IMAGE}")"; then
    switch_path="$(resolve_installed_ios "${FALLBACK_SWITCH_IMAGE}")" \
      || {
        printf '[ERROR] Legacy switch/router image is not available under %s/IOS.\n' "${images_root}" >&2
        printf '[HINT] Import the images first: bash setup.sh --profile dynamips --images\n' >&2
        exit 1
      }
  fi
fi

iosvl2_path=''
if [[ "${profile}" == 'full' ]]; then
  iosvl2_path="${images_root}/QEMU/${IOSVL2_IMAGE}"
  is_readable "${iosvl2_path}" \
    || {
      printf '[ERROR] IOSvL2 image is not available: %s\n' "${iosvl2_path}" >&2
      printf '[HINT] Import the images first: bash setup.sh --profile full --images\n' >&2
      exit 1
    }
fi

mkdir -p -- "${output_dir}"
((copy_to_user)) && mkdir -p -- "${HOME}/GNS3/appliances"
command -v "${python_bin}" >/dev/null 2>&1 \
  || { printf '[ERROR] Python interpreter not found: %s\n' "${python_bin}" >&2; exit 1; }

image_metadata() {
  local path="$1"
  printf '%s|%s|%s\n' \
    "$(basename -- "${path}")" \
    "$(file_md5 "${path}" | awk '{print $1}')" \
    "$(file_size "${path}")"
}

router_metadata="$(image_metadata "${router_path}")"
switch_metadata=''
iosvl2_metadata=''
[[ -z "${switch_path}" ]] || switch_metadata="$(image_metadata "${switch_path}")"
[[ -z "${iosvl2_path}" ]] || iosvl2_metadata="$(image_metadata "${iosvl2_path}")"

PROFILE_FOR_TEMPLATE="${profile}" \
ROUTER_METADATA="${router_metadata}" \
SWITCH_METADATA="${switch_metadata}" \
IOSVL2_METADATA="${iosvl2_metadata}" \
OUTPUT_DIR="${output_dir}" \
"${python_bin}" <<'PY'
import json
import os
from pathlib import Path

output = Path(os.environ["OUTPUT_DIR"])

def metadata(name):
    value = os.environ.get(name, "")
    if not value:
        return None
    filename, md5sum, filesize = value.split("|", 2)
    return {"filename": filename, "md5sum": md5sum, "filesize": int(filesize)}

def write(name, data):
    path = output / name
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"[OK] {path}")

router = metadata("ROUTER_METADATA")
common = {
    "tags": ["device_type:cisco_ios_telnet"],
    "category": "router",
    "vendor_name": "Cisco",
    "vendor_url": "https://www.cisco.com/",
    "documentation_url": "https://docs.gns3.com/docs/emulators/cisco-ios-images-for-dynamips",
    "product_name": "2691",
    "registry_version": 4,
    "status": "experimental",
    "maintainer": "SSA10 laboratory administrator",
    "maintainer_email": "admin@example.invalid",
}

for appliance_id, template_name, slot1, filename in (
    ("4d976437-ed2d-4ef2-a064-95d625fc56e1", "SSA10 Cisco 2691 Router", "", "ssa10-c2691-router.gns3a"),
    ("6977f299-ff41-4507-a1dd-1afbfe208cf9", "SSA10 Cisco 2691 ISP", "NM-1FE-TX", "ssa10-c2691-isp.gns3a"),
):
    data = dict(common)
    data.update({
        "appliance_id": appliance_id,
        "name": template_name,
        "description": "Cisco 2691 template generated from the approved internal image",
        "dynamips": {
            "platform": "c2691",
            "ram": 192,
            "nvram": 256,
            "startup_config": "ios_base_startup-config.txt",
            "slot0": "GT96100-FE",
            "slot1": slot1,
        },
        "images": [{**router, "version": "internal-124-13b"}],
        "versions": [{
            "name": "internal-124-13b",
            "images": {"image": router["filename"]},
        }],
    })
    write(filename, data)

if os.environ["PROFILE_FOR_TEMPLATE"] == "dynamips":
    switch = metadata("SWITCH_METADATA")
    data = dict(common)
    data.update({
        "appliance_id": "b4fc437b-a427-413f-9c9e-47c14f7a45ba",
        "name": "SSA10 Cisco EtherSwitch",
        "category": "multilayer_switch",
        "description": "Cisco 3660/3640 with NM-16ESW generated from the approved internal image",
        "product_name": "EtherSwitch NM-16ESW",
        "dynamips": {
            "platform": "c3600",
            "chassis": "3660" if switch["filename"].startswith("c3660-") else "3640",
            "ram": 256,
            "nvram": 256,
            "startup_config": "ios_base_startup-config.txt",
            "slot1": "NM-16ESW",
        },
        "images": [{**switch, "version": "internal"}],
        "versions": [{"name": "internal", "images": {"image": switch["filename"]}}],
    })
    write("ssa10-etherswitch.gns3a", data)
else:
    iosvl2 = metadata("IOSVL2_METADATA")
    data = {
        "appliance_id": "c6eef396-dd1a-4920-8da2-1777ff328f3d",
        "tags": ["device_type:cisco_ios_telnet"],
        "name": "SSA10 Cisco IOSvL2",
        "category": "multilayer_switch",
        "description": "IOSvL2 template generated from the approved image",
        "vendor_name": "Cisco",
        "vendor_url": "https://www.cisco.com/",
        "product_name": "IOSvL2",
        "registry_version": 4,
        "status": "experimental",
        "maintainer": "SSA10 laboratory administrator",
        "maintainer_email": "admin@example.invalid",
        "port_name_format": "Gi{1}/{0}",
        "port_segment_size": 4,
        "qemu": {
            "adapter_type": "e1000",
            "adapters": 16,
            "ram": 768,
            "hda_disk_interface": "virtio",
            "arch": "x86_64",
            "console_type": "telnet",
            "kvm": "require",
        },
        "images": [{**iosvl2, "version": "internal"}],
        "versions": [{"name": "internal", "images": {"hda_disk_image": iosvl2["filename"]}}],
    }
    write("ssa10-iosvl2.gns3a", data)
PY

if ((copy_to_user)); then
  install -m 0644 "${output_dir}"/*.gns3a "${HOME}/GNS3/appliances/"
  printf '[OK] Templates copied to %s\n' "${HOME}/GNS3/appliances"
  printf '[INFO] The setup wizard registers these templates automatically; standalone generation only creates files.\n'
fi
