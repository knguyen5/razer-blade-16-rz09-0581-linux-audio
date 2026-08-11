#!/usr/bin/env bash
set -Eeuo pipefail

readonly KREL="6.18.42-1-cachyos-lts"
readonly OVERRIDE_DIR="/usr/lib/modules/${KREL}/updates/razer"

[[ $EUID -eq 0 ]] || {
  printf 'Run with sudo: sudo %s\n' "$0" >&2
  exit 1
}

rm -rf -- "$OVERRIDE_DIR"
depmod "$KREL"
mkinitcpio -p linux-cachyos-lts

resolved="$(modinfo -k "$KREL" -n snd_soc_acpi_intel_match)"
case "$resolved" in
  */kernel/sound/soc/intel/common/snd-soc-acpi-intel-match.ko.zst)
    printf 'Rollback complete. Stock modules will load after reboot.\n'
    ;;
  *)
    printf 'Unexpected module resolution after rollback: %s\n' "$resolved" >&2
    exit 1
    ;;
esac
