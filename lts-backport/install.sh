#!/usr/bin/env bash
set -Eeuo pipefail

readonly KREL="6.18.42-1-cachyos-lts"
readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SOURCE_ROOT="${ROOT_DIR}/work/linux-cachyos/linux-cachyos-lts/src/cachyos-6.18.42-1"
readonly OVERRIDE_DIR="/usr/lib/modules/${KREL}/updates/razer"
readonly INITRAMFS="/boot/initramfs-linux-cachyos-lts.img"
readonly BACKUP_DIR="${ROOT_DIR}/backup"
readonly -a BUILT_MODULES=(
  "sound/soc/intel/common/snd-soc-acpi-intel-match.ko"
  "sound/soc/sdw_utils/snd-soc-sdw-utils.ko"
  "sound/soc/sof/snd-sof.ko"
  "sound/soc/sof/intel/snd-sof-intel-hda-generic.ko"
  "sound/soc/sof/intel/snd-sof-pci-intel-mtl.ko"
  "sound/soc/sof/intel/snd-sof-pci-intel-lnl.ko"
  "sound/soc/sof/intel/snd-sof-pci-intel-ptl.ko"
  "sound/soc/intel/boards/snd-soc-sof-sdw.ko"
)

[[ $EUID -eq 0 ]] || {
  printf 'Run with sudo: sudo %s\n' "$0" >&2
  exit 1
}
[[ "$(< /sys/class/dmi/id/product_name)" == "Blade 16 - RZ09-0581" ]] || {
  printf 'Unsupported laptop model; refusing to install.\n' >&2
  exit 1
}

install -d -m 755 "$BACKUP_DIR" "$OVERRIDE_DIR"
if [[ -r "$INITRAMFS" && ! -e "${BACKUP_DIR}/initramfs.before-backport" ]]; then
  cp -a -- "$INITRAMFS" "${BACKUP_DIR}/initramfs.before-backport"
fi

: >"${BACKUP_DIR}/install-manifest.txt"
printf 'kernel=%s\n' "$KREL" >>"${BACKUP_DIR}/install-manifest.txt"

for relative_module in "${BUILT_MODULES[@]}"; do
  built_module="${SOURCE_ROOT}/${relative_module}"
  module_file="${relative_module##*/}"
  compressed_file="${module_file}.zst"
  module_name="$(modinfo -F name "$built_module" 2>/dev/null || true)"
  stock_module="$(
    pacman -Qql linux-cachyos-lts |
      awk -v suffix="/${compressed_file}" 'substr($0, length($0)-length(suffix)+1) == suffix { print; exit }'
  )"

  [[ -n "$module_name" && -r "$stock_module" ]] || {
    printf 'Missing built or stock module for %s\n' "$module_file" >&2
    exit 1
  }
  vermagic="$(modinfo -F vermagic "$built_module")"
  [[ "$vermagic" == "${KREL} "* ]] || {
    printf 'Wrong vermagic for %s: %s\n' "$module_file" "$vermagic" >&2
    exit 1
  }

  if [[ ! -e "${BACKUP_DIR}/${compressed_file}.stock" ]]; then
    cp -a -- "$stock_module" "${BACKUP_DIR}/${compressed_file}.stock"
  fi
  sha256sum "$built_module" "$stock_module" >>"${BACKUP_DIR}/install-manifest.txt"

  install -m 644 "$built_module" "${OVERRIDE_DIR}/${module_file}"
  zstd --force --rm -19 "${OVERRIDE_DIR}/${module_file}" \
    -o "${OVERRIDE_DIR}/${compressed_file}"
done

depmod "$KREL"
mkinitcpio -p linux-cachyos-lts

for relative_module in "${BUILT_MODULES[@]}"; do
  module_name="$(modinfo -F name "${SOURCE_ROOT}/${relative_module}")"
  resolved="$(readlink -f "$(modinfo -k "$KREL" -n "$module_name")")"
  [[ "$resolved" == "${OVERRIDE_DIR}/"* ]] || {
    printf 'Override did not win module resolution: %s\n' "$resolved" >&2
    exit 1
  }
  printf 'Installed: %s\n' "$resolved"
done

printf 'Reboot into %s before testing audio.\n' "$KREL"
