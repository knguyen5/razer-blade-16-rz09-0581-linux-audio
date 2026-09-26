#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || {
  printf 'Run with sudo: sudo %s\n' "$0" >&2
  exit 1
}

systemctl stop razer-audio-lts-rebuild.service 2>/dev/null || true
rm -f -- \
  /etc/pacman.d/hooks/95-razer-audio-lts-rebuild.hook \
  /etc/systemd/system/razer-audio-lts-rebuild.service \
  /etc/razer-audio-lts-backport.conf \
  /usr/local/libexec/razer-audio-lts-rebuild
rm -rf -- /usr/local/lib/razer-audio-lts-backport
systemctl daemon-reload

printf 'Automatic rebuild removed. Module overrides, build cache, and backups were not changed.\n'
