#!/usr/bin/env bash
set -uo pipefail

# Read-only readiness check for a RED OS 8 GNS3 workstation.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_root="$(cd -- "${script_dir}/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "${script_dir}/lib/common.sh"
# shellcheck source=../config/lab.conf
source "${project_root}/config/lab.conf"
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

failures=0
warnings=0
dynamips_only=0
images_dir='/opt/gns3/images'

usage() {
  cat <<'EOF'
Usage:
  ./check_gns3_redos8.sh [--dynamips-only] [--images-dir DIR]

--dynamips-only  Skip KVM, QEMU and libvirt checks for an all-Dynamips lab.
--images-dir DIR  Installed image root. Default: /opt/gns3/images.
EOF
}

while (($#)); do
  case "$1" in
    --dynamips-only)
      dynamips_only=1
      ;;
    --images-dir)
      (($# >= 2)) || { printf '[ERROR] --images-dir requires a path\n' >&2; exit 2; }
      images_dir="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '[ERROR] Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

pass() {
  printf '[PASS] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*"
  warnings=$((warnings + 1))
}

fail() {
  printf '[FAIL] %s\n' "$*"
  failures=$((failures + 1))
}

check_command() {
  if command -v "$1" >/dev/null 2>&1; then
    pass "$1: $(command -v "$1")"
  else
    fail "$1 is not in PATH"
  fi
}

printf '%s\n' '=== System resources ==='
cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '0')"
ram_mib="$(awk '/MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null || printf '0')"
disk_kib="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')"
disk_gib="$((disk_kib / 1024 / 1024))"

printf 'CPU threads: %s\nRAM: %s MiB\nFree space on /: %s GiB\n' \
  "${cpu_count}" "${ram_mib}" "${disk_gib}"

((cpu_count >= 8)) && pass 'At least 8 CPU threads are available' \
  || fail 'Fewer than 8 CPU threads'
((ram_mib >= 15000)) && pass 'At least 16 GB-class RAM is installed' \
  || fail 'Less than approximately 16 GB RAM'
((disk_gib >= 50)) && pass 'At least 50 GiB is free on /' \
  || warn 'Less than 50 GiB is free on /'

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" == *redos* || "${NAME:-}" == *'RED OS'* || "${NAME:-}" == *'РЕД ОС'* ]]; then
    pass "Operating system: ${PRETTY_NAME:-RED OS}"
  else
    fail "Expected RED OS, detected ${PRETTY_NAME:-unknown}"
  fi
fi

if ((dynamips_only)); then
  pass 'Dynamips-only profile selected; KVM and libvirt checks are skipped'
else
  if grep -Eq '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
    pass 'CPU virtualization flags are present'
  else
    fail 'CPU virtualization flags are missing; check BIOS/UEFI'
  fi

  if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    pass '/dev/kvm is readable and writable by the current user'
  else
    fail 'No user access to /dev/kvm; check the kvm group and re-login'
  fi

  if systemctl is-active --quiet libvirtd; then
    pass 'libvirtd is active'
  else
    fail 'libvirtd is not active'
  fi
fi

printf '%s\n' '=== Executables ==='
executables=(gns3 gns3server dynamips ubridge vpcs)
((dynamips_only)) || executables+=(virsh)
for executable in "${executables[@]}"; do
  check_command "${executable}"
done

if command -v wireshark >/dev/null 2>&1; then
  pass "Recommended Wireshark: $(command -v wireshark)"
else
  warn 'Recommended Wireshark is not installed; packet capture from GNS3 will be unavailable'
fi

if ((!dynamips_only)); then
  if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    pass "QEMU: $(command -v qemu-system-x86_64)"
  elif command -v qemu-kvm >/dev/null 2>&1; then
    pass "QEMU: $(command -v qemu-kvm)"
  elif [[ -x /usr/libexec/qemu-kvm ]]; then
    pass 'QEMU: /usr/libexec/qemu-kvm'
  else
    fail 'No QEMU system binary was found'
  fi
fi

printf '%s\n' '=== Versions ==='
if command -v gns3 >/dev/null 2>&1; then
  gns3_gui_version="$(timeout 10 gns3 --version 2>&1 | head -n 1 || true)"
  [[ "${gns3_gui_version}" == *"${GNS3_VERSION}"* ]] \
    && pass "GNS3 GUI ${GNS3_VERSION}" \
    || fail "Unexpected GNS3 GUI version: ${gns3_gui_version:-unavailable}"
fi
if command -v gns3server >/dev/null 2>&1; then
  gns3_server_version="$(timeout 10 gns3server --version 2>&1 | head -n 1 || true)"
  [[ "${gns3_server_version}" == *"${GNS3_VERSION}"* ]] \
    && pass "GNS3 Server ${GNS3_VERSION}" \
    || fail "Unexpected GNS3 Server version: ${gns3_server_version:-unavailable}"
fi
if command -v dynamips >/dev/null 2>&1; then
  dynamips_output="$(timeout 10 dynamips -P none 2>&1 || true)"
  dynamips_detected_version="$(extract_dynamips_version "${dynamips_output}")"
  [[ "${dynamips_detected_version}" == "${DYNAMIPS_VERSION}" ]] \
    && pass "Dynamips ${DYNAMIPS_VERSION}" \
    || fail "Unexpected Dynamips version: ${dynamips_detected_version:-unavailable}"
fi
if command -v ubridge >/dev/null 2>&1; then
  ubridge_output="$(timeout 10 ubridge -v 2>&1 | head -n 1 || true)"
  [[ "${ubridge_output}" == *"${UBRIDGE_VERSION}"* ]] \
    && pass "uBridge ${UBRIDGE_VERSION}" \
    || fail "Unexpected uBridge version: ${ubridge_output:-unavailable}"
fi
if command -v vpcs >/dev/null 2>&1; then
  vpcs_output="$(timeout 10 vpcs -v 2>&1 | head -n 2 || true)"
  [[ "${vpcs_output}" == *"${VPCS_VERSION}"* || "${vpcs_output}" == *'version 0.8'* || "${vpcs_output}" == *'Ver 0.8'* ]] \
    && pass "VPCS ${VPCS_VERSION}" \
    || fail "Unexpected VPCS version: ${vpcs_output:-unavailable}"
fi

printf '%s\n' '=== uBridge permissions ==='
if command -v ubridge >/dev/null 2>&1; then
  ubridge_path="$(command -v ubridge)"
  capabilities="$(getcap "${ubridge_path}" 2>/dev/null || true)"
  if [[ "${capabilities}" == *cap_net_admin* && "${capabilities}" == *cap_net_raw* ]]; then
    pass "${capabilities}"
  else
    fail 'uBridge lacks cap_net_admin and/or cap_net_raw'
  fi
fi

printf '%s\n' '=== Image directories ==='

can_read_path() {
  local path="$1"
  [[ -r "${path}" ]] && return 0
  command -v sudo >/dev/null 2>&1 && sudo test -r "${path}"
}

can_access_directory() {
  local path="$1"
  if [[ -d "${path}" && -r "${path}" && -x "${path}" ]]; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 \
    && sudo test -d "${path}" \
    && sudo test -r "${path}" \
    && sudo test -x "${path}"
}

image_dirs=("${images_dir}/IOS")
((dynamips_only)) || image_dirs+=("${images_dir}/QEMU")
for image_dir in "${image_dirs[@]}"; do
  if can_access_directory "${image_dir}"; then
    pass "Image directory is accessible: ${image_dir}"
  else
    fail "Missing or unreadable directory: ${image_dir}"
  fi
done

if can_read_path "${images_dir}/SHA256SUMS"; then
  pass 'SHA256SUMS manifest exists'
  if [[ -r "${images_dir}/SHA256SUMS" ]]; then
    (
      cd "${images_dir}" || exit 1
      sed 's#  /opt/gns3/images/#  #' SHA256SUMS | sha256sum -c -
    ) || fail 'One or more image checksums do not match'
  else
    sudo sha256sum -c "${images_dir}/SHA256SUMS" \
      || fail 'One or more image checksums do not match'
  fi
else
  warn 'SHA256SUMS is absent; install images with install_gns3_images.sh'
fi

expected_router="${ROUTER_IMAGE%.bin}.image"
if can_read_path "${images_dir}/IOS/${expected_router}" \
  || can_read_path "${images_dir}/IOS/${ROUTER_IMAGE}"; then
  pass "Router image is installed: ${ROUTER_IMAGE}"
else
  fail "Router image is missing: ${ROUTER_IMAGE}"
fi

if ((dynamips_only)); then
  expected_switch="${SWITCH_IMAGE%.bin}.image"
  fallback_switch="${FALLBACK_SWITCH_IMAGE%.bin}.image"
  if can_read_path "${images_dir}/IOS/${expected_switch}" \
    || can_read_path "${images_dir}/IOS/${SWITCH_IMAGE}"; then
    pass "Switch image is installed: ${SWITCH_IMAGE}"
  elif can_read_path "${images_dir}/IOS/${fallback_switch}" \
    || can_read_path "${images_dir}/IOS/${FALLBACK_SWITCH_IMAGE}"; then
    warn "Fallback switch image is installed: ${FALLBACK_SWITCH_IMAGE}"
  else
    fail "No supported switch image is installed"
  fi
else
  can_read_path "${images_dir}/QEMU/${IOSVL2_IMAGE}" \
    && pass "IOSvL2 image is installed: ${IOSVL2_IMAGE}" \
    || fail "IOSvL2 image is missing: ${IOSVL2_IMAGE}"
fi

printf '%s\n' '=== User groups and local server exposure ==='
active_groups="$(id -nG 2>/dev/null || true)"
[[ " ${active_groups} " == *' gns3lab '* ]] \
  && pass 'Current session includes the gns3lab group' \
  || fail 'Current session does not include gns3lab; log out and back in'

if ((!dynamips_only)); then
  for required_group in libvirt kvm; do
    [[ " $(id -nG 2>/dev/null || true) " == *" ${required_group} "* ]] \
      && pass "Current session includes ${required_group}" \
      || fail "Current session does not include ${required_group}"
  done
fi

if command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | awk '$4 ~ /(^|:)3080$/ {print $4}' \
      | grep -Eq '^(0\.0\.0\.0:3080|\[::\]:3080|\*:3080)$'; then
    fail 'GNS3 port 3080 is listening on all interfaces; bind it to 127.0.0.1'
  elif ss -ltn 2>/dev/null | awk '$4 ~ /(^|:)3080$/ {print $4}' | grep -q .; then
    pass 'GNS3 port 3080 is not exposed on all interfaces'
  else
    warn 'GNS3 Server is not currently listening on port 3080'
  fi
fi

gns3_config_file="${HOME}/.config/GNS3/2.2/gns3_server.conf"
if [[ -r "${gns3_config_file}" ]]; then
  if awk '
    /^\[Server\][[:space:]]*$/ {in_server=1; next}
    /^\[/ {in_server=0}
    in_server && $0 ~ /^[[:space:]]*host[[:space:]]*=[[:space:]]*127\.0\.0\.1[[:space:]]*$/ {found=1}
    END {exit !found}
  ' "${gns3_config_file}"; then
    pass 'GNS3 Server is configured for 127.0.0.1'
  else
    fail "GNS3 Server is not bound to 127.0.0.1 in ${gns3_config_file}"
  fi
else
  fail "GNS3 Server configuration is missing: ${gns3_config_file}"
fi

printf '%s\n' '=== GNS3 Server API and registered templates ==='
if command -v gns3server >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  template_profile='full'
  ((dynamips_only)) && template_profile='dynamips'
  if python3 "${script_dir}/register_appliances.py" \
      --profile "${template_profile}" --expected-version "${GNS3_VERSION}" --check; then
    pass 'Local GNS3 API and all three SSA10 templates are ready'
  else
    fail "GNS3 API or templates check failed. Run bash setup.sh --profile ${template_profile} --templates"
  fi
else
  fail 'Cannot check GNS3 API without gns3server and python3'
fi

printf '%s\n' '=== Summary ==='
printf 'Failures: %d\nWarnings: %d\n' "${failures}" "${warnings}"

((failures == 0))
