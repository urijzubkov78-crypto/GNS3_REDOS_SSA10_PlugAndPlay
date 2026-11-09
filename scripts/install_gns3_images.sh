#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/logging.sh
source "${script_dir}/lib/logging.sh"
log_child_traps

# Installs locally supplied, licensed images into /opt/gns3/images.
# It intentionally does not automate authenticated Cisco downloads.

allow_unknown=0
dry_run=0
images_root="${GNS3_IMAGES_ROOT:-/opt/gns3/images}"
use_sudo=1
[[ "${images_root}" == '/opt/gns3/images' ]] || use_sudo=0

declare -A known_md5=(
  ['c3725-adventerprisek9-mz.124-15.T14.bin']='42baf17af10d9a1471bf542f0bfd07c7'
  ['c3725-adventerprisek9-mz.124-15.T14.image']='64f8c427ed48fd21bd02cf1ff254c4eb'
  ['c3745-adventerprisek9-mz.124-25d.bin']='563797308a3036337c3dee9b4ab54649'
  ['c3745-adventerprisek9-mz.124-25d.image']='ddbaf74274822b50fa9670e10c75b08f'
  ['vios_l2-adventerprisek9-m.ssa.high_iron_20200929.qcow2']='99ecab32de12410c533e6abd4e9710aa'
  ['vios_l2-adventerprisek9-m.ssa.high_iron_20190423.qcow2']='71cacb678f98a106f99e889b97b34686'
)

declare -A converted_name=(
  ['c3725-adventerprisek9-mz.124-15.T14.bin']='c3725-adventerprisek9-mz.124-15.T14.image'
  ['c3745-adventerprisek9-mz.124-25d.bin']='c3745-adventerprisek9-mz.124-25d.image'
)

declare -A converted_md5=(
  ['c3725-adventerprisek9-mz.124-15.T14.bin']='64f8c427ed48fd21bd02cf1ff254c4eb'
  ['c3745-adventerprisek9-mz.124-25d.bin']='ddbaf74274822b50fa9670e10c75b08f'
)

usage() {
  cat <<'EOF'
Usage:
  ./install_gns3_images.sh [--dry-run] [--allow-unknown] IMAGE [IMAGE ...]

Examples:
  ./install_gns3_images.sh /mnt/media/c3725-...image /mnt/media/vios_l2-...qcow2
  ./install_gns3_images.sh /mnt/repo/ios-2691/c2691-...bin /mnt/repo/ios-3660/c3660-...bin

Unknown filenames or checksum mismatches are rejected by default.
An unknown image is accepted when an adjacent IMAGE.md5 or BASENAME.md5 file
contains its MD5 checksum. This validates transfer integrity, not provenance.
--dry-run validates and unpacks images without writing to /opt.
--allow-unknown permits a locally approved image not listed in the script.
EOF
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

as_admin() {
  if ((use_sudo)); then
    sudo "$@"
  else
    "$@"
  fi
}

files=()
while (($#)); do
  case "$1" in
    --allow-unknown)
      allow_unknown=1
      ;;
    --dry-run)
      dry_run=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      files+=("$1")
      ;;
  esac
  shift
done

((${#files[@]} > 0)) || die 'Specify at least one image file.'
if ((!dry_run && use_sudo)); then
  command -v sudo >/dev/null 2>&1 || die 'sudo is required.'
fi
command -v md5sum >/dev/null 2>&1 || die 'md5sum is required.'
command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required.'
command -v unzip >/dev/null 2>&1 || die 'unzip is required for Cisco IOS .bin files.'

work_dir="$(mktemp -d -t gns3-images.XXXXXX)"
cleanup() {
  rm -rf -- "${work_dir}"
}
trap cleanup EXIT

if ((!dry_run)); then
  if ((use_sudo)); then
    sudo groupadd -f gns3lab
    sudo install -d -o root -g gns3lab -m 2750 "${images_root}/IOS"
    sudo install -d -o root -g gns3lab -m 2750 "${images_root}/QEMU"
  else
    mkdir -p -- "${images_root}/IOS" "${images_root}/QEMU"
    chmod 0750 "${images_root}/IOS" "${images_root}/QEMU" 2>/dev/null || true
  fi
fi

for source_file in "${files[@]}"; do
  [[ -f "${source_file}" ]] || die "File not found: ${source_file}"
  base_name="$(basename -- "${source_file}")"
  actual_md5="$(md5sum -- "${source_file}" | awk '{print $1}')"
  registry_md5="${known_md5[${base_name}]:-}"
  sidecar_md5=''
  sidecar_file=''

  for candidate in "${source_file}.md5" "${source_file%.*}.md5"; do
    if [[ -f "${candidate}" ]]; then
      sidecar_file="${candidate}"
      sidecar_text="$(tr '[:upper:]' '[:lower:]' < "${candidate}")"
      if [[ "${sidecar_text}" =~ ([0-9a-f]{32}) ]]; then
        sidecar_md5="${BASH_REMATCH[1]}"
      else
        die "No valid MD5 digest in ${candidate}"
      fi
      break
    fi
  done

  if [[ -n "${registry_md5}" && -n "${sidecar_md5}" && "${registry_md5}" != "${sidecar_md5}" ]]; then
    die "Sidecar checksum for ${base_name} conflicts with the built-in GNS3 registry checksum"
  fi

  expected_md5="${registry_md5:-${sidecar_md5}}"

  if [[ -n "${expected_md5}" ]]; then
    [[ "${actual_md5}" == "${expected_md5}" ]] \
      || die "MD5 mismatch for ${base_name}: expected ${expected_md5}, got ${actual_md5}"
    if [[ -n "${sidecar_file}" ]]; then
      printf '[OK] MD5 verified using %s\n' "${sidecar_file}"
    else
      printf '[OK] MD5 verified using the built-in GNS3 registry value\n'
    fi
  elif ((allow_unknown)); then
    printf '[WARN] Installing an unlisted but locally approved image: %s\n' "${base_name}" >&2
  else
    die "Unknown image '${base_name}' and no adjacent .md5 file. Use --allow-unknown only after internal approval."
  fi

  install_source="${source_file}"
  install_name="${base_name}"

  if [[ -n "${converted_name[${base_name}]:-}" ]]; then
    install_name="${converted_name[${base_name}]}"
    install_source="${work_dir}/${install_name}"
    unzip -p "${source_file}" > "${install_source}"
    unpacked_md5="$(md5sum -- "${install_source}" | awk '{print $1}')"
    [[ "${unpacked_md5}" == "${converted_md5[${base_name}]}" ]] \
      || die "MD5 mismatch after unpacking ${base_name}: expected ${converted_md5[${base_name}]}, got ${unpacked_md5}"
    printf '[OK] Unpacked %s to %s\n' "${base_name}" "${install_name}"
  elif [[ "${base_name}" == *.bin ]] && unzip -tqq "${source_file}" >/dev/null 2>&1; then
    install_name="${base_name%.bin}.image"
    install_source="${work_dir}/${install_name}"
    unzip -p "${source_file}" > "${install_source}"
    unpacked_md5="$(md5sum -- "${install_source}" | awk '{print $1}')"
    printf '[OK] Unpacked %s to %s (MD5 %s)\n' \
      "${base_name}" "${install_name}" "${unpacked_md5}"
  fi

  case "${install_name}" in
    *.qcow2)
      destination_dir="${images_root}/QEMU"
      ;;
    *.image|*.bin)
      destination_dir="${images_root}/IOS"
      ;;
    *)
      die "Unsupported image extension: ${install_name}"
      ;;
  esac

  if ((dry_run)); then
    printf '[DRY-RUN] %s -> %s/%s\n' \
      "${source_file}" "${destination_dir}" "${install_name}"
    continue
  fi

  destination_path="${destination_dir}/${install_name}"
  source_install_md5="$(md5sum -- "${install_source}" | awk '{print $1}')"
  if ((use_sudo)); then
    sudo install -o root -g gns3lab -m 0640 "${install_source}" "${destination_path}"
  else
    cp -f -- "${install_source}" "${destination_path}"
    chmod 0640 "${destination_path}" 2>/dev/null || true
  fi

  as_admin test -s "${destination_path}" \
    || die "Installed image is absent or empty: ${destination_path}"
  installed_md5="$(as_admin md5sum -- "${destination_path}" | awk '{print $1}')"
  [[ "${installed_md5}" == "${source_install_md5}" ]] \
    || die "Installed image checksum mismatch: ${destination_path}"

  printf '[OK] Installed and verified: %s\n' "${destination_path}"
  as_admin sha256sum "${destination_path}"
done

if ((dry_run)); then
  printf '[OK] Validation completed; no files were installed.\n'
  exit 0
fi

manifest_tmp="${work_dir}/SHA256SUMS"

while IFS= read -r -d '' image_file; do
  as_admin sha256sum "${image_file}"
done < <(as_admin find "${images_root}/IOS" "${images_root}/QEMU" -maxdepth 1 -type f -print0) \
  > "${manifest_tmp}"

if ((use_sudo)); then
  sudo install -o root -g gns3lab -m 0640 "${manifest_tmp}" "${images_root}/SHA256SUMS"
else
  cp -f -- "${manifest_tmp}" "${images_root}/SHA256SUMS"
  chmod 0640 "${images_root}/SHA256SUMS" 2>/dev/null || true
fi

as_admin test -s "${images_root}/SHA256SUMS" \
  || die "Image manifest was not created: ${images_root}/SHA256SUMS"
printf '[OK] Manifest: %s/SHA256SUMS\n' "${images_root}"
printf '[INFO] Installed IOS images: %s/IOS\n' "${images_root}"
printf '[INFO] Installed QEMU images: %s/QEMU\n' "${images_root}"
