#!/usr/bin/env bash
set -Eeuo pipefail

# Automated installation of the GNS3 workstation components on RED OS 8.
# Run as a normal user with sudo privileges. Cisco images are not downloaded.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_root="$(cd -- "${script_dir}/.." && pwd -P)"
# shellcheck source=../config/lab.conf
source "${project_root}/config/lab.conf"
# shellcheck source=lib/logging.sh
source "${script_dir}/lib/logging.sh"
log_child_traps

readonly GNS3_VERSION="${GNS3_VERSION:-2.2.61}"
readonly DYNAMIPS_VERSION="${DYNAMIPS_VERSION:-0.2.25}"
readonly UBRIDGE_VERSION="${UBRIDGE_VERSION:-1.2.0}"
readonly VPCS_VERSION="${VPCS_VERSION:-0.8.4}"

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

full_update=0
profile="${DEFAULT_PROFILE:-dynamips}"
install_wireshark=1
install_virt_tools=1
install_extra_tools=1

usage() {
  cat <<'EOF'
Usage: ./install_gns3_redos8.sh [--profile dynamips|full] [options]

  --profile      dynamips installs c2691/c3660 support without KVM.
                 full also installs QEMU/KVM and libvirt for IOSvL2.
  --full-update  Run dnf update before installing packages.
  --skip-wireshark   Skip the recommended Wireshark package.
  --skip-virt-tools  Skip optional virt-manager/virt-install/OVMF packages.
  --skip-extra-tools Skip optional mtools package.
  --minimal          Install only components required for the selected profile.
  -h, --help     Show this help.

Environment overrides:
  GNS3_VERSION, DYNAMIPS_VERSION, UBRIDGE_VERSION, VPCS_VERSION
EOF
}

log() {
  export GNS3_STAGE="$*"
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --profile)
      (($# >= 2)) || die 'A value is required after --profile.'
      profile="$2"
      shift
      ;;
    --full-update)
      full_update=1
      ;;
    --skip-wireshark) install_wireshark=0 ;;
    --skip-virt-tools) install_virt_tools=0 ;;
    --skip-extra-tools) install_extra_tools=0 ;;
    --minimal)
      install_wireshark=0
      install_virt_tools=0
      install_extra_tools=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
  shift
done

case "${profile}" in
  dynamips|full) ;;
  *) die "Unknown profile '${profile}'. Use dynamips or full." ;;
esac
[[ "${profile}" == 'full' ]] || install_virt_tools=0

[[ ${EUID} -ne 0 ]] || die 'Run this script as a normal user, not as root.'
command -v sudo >/dev/null 2>&1 || die 'sudo is required.'
command -v dnf >/dev/null 2>&1 || die 'dnf was not found. This script targets RED OS 8.'

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" != *redos* && "${NAME:-}" != *'RED OS'* && "${NAME:-}" != *'РЕД ОС'* ]]; then
    warn "The detected OS is '${PRETTY_NAME:-unknown}', not RED OS. Continue only if it is RPM-compatible."
  fi
fi

sudo -v

log 'Refreshing package metadata.'
sudo dnf makecache

if ((full_update)); then
  log 'Installing all available system updates.'
  sudo dnf update -y
fi

log 'Installing build tools and Python.'
sudo dnf install -y \
  git gcc gcc-c++ make cmake \
  elfutils-libelf-devel libpcap-devel libcap \
  python3 python3-pip python3-devel \
  curl tar unzip

if ! sudo dnf install -y pipx; then
  warn 'The pipx RPM package was not found; installing pipx for the current user.'
  python3 -m pip install --user --upgrade pipx
fi

python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' \
  || die 'GNS3 2.2.61 requires Python 3.9 or newer.'

if [[ "${profile}" == 'full' ]]; then
  log 'Installing required QEMU/KVM and libvirt components.'
  sudo dnf install -y \
    libvirt qemu-kvm \
    boost-random boost-program-options boost-regex

  if ((install_virt_tools)); then
    log 'Installing recommended virtualization management tools.'
    if ! sudo dnf install -y virt-install virt-manager openssh-askpass OVMF; then
      warn 'Some recommended virtualization management tools were not installed.'
    fi
  fi
fi

log 'Installing required console utilities.'
sudo dnf install -y xterm

if ((install_extra_tools)); then
  log 'Installing additional helper tools.'
  sudo dnf install -y mtools || warn 'Optional package mtools was not installed.'
fi

if ! sudo dnf install -y telnet; then
  if ! sudo dnf install -y inetutils; then
    die 'No telnet or inetutils package was found; a GNS3 console client is required.'
  fi
fi

if ((install_wireshark)); then
  log 'Installing recommended Wireshark packet analyzer.'
  if ! sudo dnf install -y wireshark; then
    if ! sudo dnf install -y wireshark-qt; then
      warn 'Neither wireshark nor wireshark-qt was installed; packet capture will be unavailable.'
    fi
  fi
fi

if [[ "${profile}" == 'full' ]]; then
  sudo systemctl enable --now libvirtd

  for group_name in libvirt kvm; do
    if getent group "${group_name}" >/dev/null; then
      sudo usermod -aG "${group_name}" "${USER}"
    else
      warn "Group '${group_name}' does not exist after package installation."
    fi
  done
fi

if ((install_wireshark)) && getent group wireshark >/dev/null; then
  sudo usermod -aG wireshark "${USER}"
fi

log "Installing GNS3 GUI and Server ${GNS3_VERSION} with pipx."
python3 -m pipx ensurepath
python3 -m pipx install --force "gns3-server==${GNS3_VERSION}"
python3 -m pipx install --force "gns3-gui==${GNS3_VERSION}"
python3 -m pipx inject --force gns3-gui "gns3-server==${GNS3_VERSION}" PyQt6

build_root="$(mktemp -d -t gns3-redos-build.XXXXXX)"
cleanup() {
  rm -rf -- "${build_root}"
}
trap cleanup EXIT

jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')"
((jobs > 8)) && jobs=8

log "Building Dynamips ${DYNAMIPS_VERSION}."
git clone --depth 1 --branch "v${DYNAMIPS_VERSION}" \
  https://github.com/GNS3/dynamips.git "${build_root}/dynamips"
cmake -S "${build_root}/dynamips" -B "${build_root}/dynamips/build" \
  -DDYNAMIPS_CODE=stable \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "${build_root}/dynamips/build" --parallel "${jobs}"
sudo cmake --install "${build_root}/dynamips/build"
sudo ldconfig

log "Building uBridge ${UBRIDGE_VERSION}."
git clone --depth 1 --branch "v${UBRIDGE_VERSION}" \
  https://github.com/GNS3/ubridge.git "${build_root}/ubridge"
make -C "${build_root}/ubridge" -j"${jobs}"
sudo make -C "${build_root}/ubridge" install

ubridge_path="$(command -v ubridge || true)"
[[ -n "${ubridge_path}" ]] || die 'uBridge was installed but is not in PATH.'
sudo setcap cap_net_admin,cap_net_raw=ep "${ubridge_path}"

log "Building VPCS ${VPCS_VERSION}."
git clone --depth 1 --branch "v${VPCS_VERSION}" \
  https://github.com/GNS3/vpcs.git "${build_root}/vpcs"
(
  cd "${build_root}/vpcs/src"
  ./mk.sh 64
)
sudo install -m 0755 "${build_root}/vpcs/src/vpcs" /usr/local/bin/vpcs

log 'Creating protected image directories.'
sudo groupadd -f gns3lab
sudo usermod -aG gns3lab "${USER}"
sudo install -d -o root -g gns3lab -m 2750 /opt/gns3
sudo install -d -o root -g gns3lab -m 2750 /opt/gns3/images
sudo install -d -o root -g gns3lab -m 2750 /opt/gns3/images/IOS
sudo install -d -o root -g gns3lab -m 2750 /opt/gns3/images/QEMU
install -d -m 0750 "${HOME}/GNS3/projects"
install -d -m 0750 "${HOME}/GNS3/appliances" "${HOME}/GNS3/configs"

home_images_link="${HOME}/GNS3/images"
if [[ -L "${home_images_link}" ]]; then
  current_link_target="$(readlink -- "${home_images_link}" || true)"
  if [[ "${current_link_target}" == '/opt/gns3/images' ]]; then
    log "Home image link already exists: ${home_images_link} -> /opt/gns3/images"
  else
    warn "Keeping existing symbolic link ${home_images_link} -> ${current_link_target}."
  fi
elif [[ -e "${home_images_link}" ]]; then
  warn "Keeping existing ${home_images_link}; protected images remain available in /opt/gns3/images."
else
  ln -s /opt/gns3/images "${home_images_link}"
  log "Created a convenient home link: ${home_images_link} -> /opt/gns3/images"
fi

log 'Configuring the local GNS3 Server on 127.0.0.1:3080.'
gns3_config_dir="${HOME}/.config/GNS3/2.2"
gns3_config_file="${gns3_config_dir}/gns3_server.conf"
install -d -m 0700 "${gns3_config_dir}"
if [[ -f "${gns3_config_file}" ]]; then
  cp -a -- "${gns3_config_file}" \
    "${gns3_config_file}.backup.$(date +%Y%m%d-%H%M%S)"
fi

PROFILE_FOR_CONFIG="${profile}" GNS3_CONFIG_FILE="${gns3_config_file}" python3 <<'PY'
import configparser
import os
import pathlib
import tempfile

path = pathlib.Path(os.environ["GNS3_CONFIG_FILE"])
profile = os.environ["PROFILE_FOR_CONFIG"]
config = configparser.ConfigParser()
if path.exists():
    config.read(path, encoding="utf-8")

if not config.has_section("Server"):
    config.add_section("Server")
server = config["Server"]
server["host"] = "127.0.0.1"
server["port"] = "3080"
server["local"] = "True"
server["allow_remote_console"] = "False"
server["auth"] = "False"
server["images_path"] = "/opt/gns3/images"
server["projects_path"] = str(pathlib.Path.home() / "GNS3" / "projects")
server["appliances_path"] = str(pathlib.Path.home() / "GNS3" / "appliances")
server["configs_path"] = str(pathlib.Path.home() / "GNS3" / "configs")

if not config.has_section("Qemu"):
    config.add_section("Qemu")
qemu = config["Qemu"]
enabled = "True" if profile == "full" else "False"
qemu["enable_hardware_acceleration"] = enabled
qemu["require_hardware_acceleration"] = enabled

fd, temporary_name = tempfile.mkstemp(prefix="gns3-server-", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        config.write(stream)
    os.chmod(temporary_name, 0o600)
    os.replace(temporary_name, path)
finally:
    if os.path.exists(temporary_name):
        os.unlink(temporary_name)
PY

state_file="${build_root}/versions.env"
printf '%s\n' \
  "PROFILE=${profile}" \
  "GNS3_VERSION=${GNS3_VERSION}" \
  "DYNAMIPS_VERSION=${DYNAMIPS_VERSION}" \
  "UBRIDGE_VERSION=${UBRIDGE_VERSION}" \
  "VPCS_VERSION=${VPCS_VERSION}" > "${state_file}"
printf '%s\n' \
  "WIRESHARK_ENABLED=${install_wireshark}" \
  "VIRT_TOOLS_ENABLED=${install_virt_tools}" \
  "EXTRA_TOOLS_ENABLED=${install_extra_tools}" >> "${state_file}"
sudo install -o root -g gns3lab -m 0640 "${state_file}" /opt/gns3/versions.env

log 'Installed components:'
printf '  GNS3 GUI/Server: %s\n' "${GNS3_VERSION}"
printf '  Dynamips:        %s\n' "${DYNAMIPS_VERSION}"
printf '  uBridge:         %s\n' "${UBRIDGE_VERSION}"
printf '  VPCS:            %s\n' "${VPCS_VERSION}"
printf '  Profile:         %s\n' "${profile}"
printf '  Wireshark:       %s\n' "$([[ ${install_wireshark} -eq 1 ]] && printf enabled || printf skipped)"
printf '  Virt tools:      %s\n' "$([[ ${install_virt_tools} -eq 1 ]] && printf enabled || printf skipped)"
printf '  Extra tools:     %s\n' "$([[ ${install_extra_tools} -eq 1 ]] && printf enabled || printf skipped)"

cat <<'EOF'

Installation is complete.

Required next steps:
1. Reboot or log out and log in again to apply group membership.
2. Copy licensed Cisco images with install_gns3_images.sh.
3. Run check_gns3_redos8.sh.
4. Start GNS3 with: gns3
5. Keep the local server bound to 127.0.0.1:3080.
EOF
