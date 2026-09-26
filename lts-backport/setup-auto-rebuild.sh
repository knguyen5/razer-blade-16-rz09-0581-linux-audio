#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly BUILD_USER="${SUDO_USER:-}"
readonly TOOL_ROOT="/usr/local/lib/razer-audio-lts-backport"
readonly WORK_ROOT="/var/cache/razer-audio-lts-backport"
readonly BACKUP_ROOT="/var/lib/razer-audio-lts-backport/backups"

[[ $EUID -eq 0 ]] || {
  printf 'Run with sudo: sudo %s\n' "$0" >&2
  exit 1
}
[[ -n "$BUILD_USER" && "$BUILD_USER" != root ]] || {
  printf 'Run through sudo from the normal user that owns this repository.\n' >&2
  exit 1
}
BUILD_HOME="$(getent passwd "$BUILD_USER" | cut -d: -f6)"
BUILD_GROUP="$(id -gn "$BUILD_USER")"
[[ -n "$BUILD_HOME" && -d "$BUILD_HOME" ]] || {
  printf 'Could not determine the home directory for %s.\n' "$BUILD_USER" >&2
  exit 1
}

install -d -m 755 "$TOOL_ROOT" "${TOOL_ROOT}/patches"
install -d -o "$BUILD_USER" -g "$BUILD_GROUP" -m 755 "$WORK_ROOT"
install -d -m 755 "$BACKUP_ROOT"
install -m 755 "${ROOT_DIR}/build.sh" "${ROOT_DIR}/install.sh" "$TOOL_ROOT/"
install -m 644 "${ROOT_DIR}/patches/rt721-function-topology.patch" \
  "${ROOT_DIR}/patches/sof-intel-desc-abi.patch" "${TOOL_ROOT}/patches/"
install -Dm755 \
  "${ROOT_DIR}/automation/razer-audio-lts-rebuild" \
  /usr/local/libexec/razer-audio-lts-rebuild
install -Dm644 \
  "${ROOT_DIR}/automation/razer-audio-lts-rebuild.service" \
  /etc/systemd/system/razer-audio-lts-rebuild.service
install -Dm644 \
  "${ROOT_DIR}/automation/95-razer-audio-lts-rebuild.hook" \
  /etc/pacman.d/hooks/95-razer-audio-lts-rebuild.hook

{
  printf 'BUILD_USER=%q\n' "$BUILD_USER"
  printf 'BUILD_HOME=%q\n' "$BUILD_HOME"
  printf 'TOOL_ROOT=%q\n' "$TOOL_ROOT"
  printf 'WORK_ROOT=%q\n' "$WORK_ROOT"
  printf 'BACKUP_ROOT=%q\n' "$BACKUP_ROOT"
} >/etc/razer-audio-lts-backport.conf
chmod 644 /etc/razer-audio-lts-backport.conf

systemctl daemon-reload
printf 'Automatic rebuild installed for future CachyOS LTS kernel updates.\n'
printf 'Status: systemctl status razer-audio-lts-rebuild.service\n'
