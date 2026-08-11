#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROGRAM="${0##*/}"
readonly SUPPORTED_PRODUCT="Blade 16 - RZ09-0581"
readonly STALE_TOPOLOGY="/usr/lib/firmware/intel/sof-ipc4-tplg/sof-ptl-rt721-2ch.tplg"
readonly UCM_ROOT="/usr/share/alsa/ucm2"
readonly COMBINED_UCM="${UCM_ROOT}/codecs/rt721+rt1320/init.conf"
readonly RT721_UCM="${UCM_ROOT}/codecs/rt721/init.conf"
readonly RT1320_UCM="${UCM_ROOT}/codecs/rt1320/init.conf"
readonly STATE_ROOT="/var/lib/razer-audio-fix"
readonly EXPECTED_UCM='# Combined RT721 headset codec and RT1320 speaker amplifier initialization.

Include.rt721.File "/codecs/rt721/init.conf"
Include.rt1320.File "/codecs/rt1320/init.conf"'

ACTION="diagnose"
DISTRO_OVERRIDE=""
DRY_RUN=0
FORCE_MODEL=0
LAST_BACKUP=""
TOPOLOGY_CHANGED=0

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Usage: ${PROGRAM} [diagnose|install|test|restore] [options]

Actions:
  diagnose                 Collect read-only hardware and audio information
  install                  Install packages and apply the guarded fix
  test                     Prompt before running stereo speaker tests
  restore                  Restore the most recent pre-install backup

Options:
  --distro DISTRO          Override detection: arch, debian, fedora, opensuse
  --dry-run                Print mutating commands without executing them
  --force-unsupported-model
                           Allow install on a non-matching DMI product
  -h, --help               Show this help

No sound is played without an explicit confirmation.
EOF
}

while (($#)); do
  case "$1" in
    diagnose|install|test|restore) ACTION="$1" ;;
    --distro)
      (($# >= 2)) || die "--distro requires a value"
      DISTRO_OVERRIDE="$2"
      shift
      ;;
    --dry-run) DRY_RUN=1 ;;
    --force-unsupported-model) FORCE_MODEL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

read_product() {
  if [[ -r /sys/class/dmi/id/product_name ]]; then
    tr -d '\n' </sys/class/dmi/id/product_name
  else
    printf 'unknown'
  fi
}

detect_distro() {
  if [[ -n "$DISTRO_OVERRIDE" ]]; then
    case "$DISTRO_OVERRIDE" in
      arch|debian|fedora|opensuse) printf '%s' "$DISTRO_OVERRIDE"; return ;;
      *) die "unsupported distro override: $DISTRO_OVERRIDE" ;;
    esac
  fi

  [[ -r /etc/os-release ]] || die "cannot detect distribution: /etc/os-release is missing"
  # Values in os-release are distribution-controlled, not user input.
  # shellcheck disable=SC1091
  source /etc/os-release
  local candidates=" ${ID:-} ${ID_LIKE:-} "
  case "$candidates" in
    *" arch "*|*" cachyos "*|*" manjaro "*) printf 'arch' ;;
    *" debian "*|*" ubuntu "*) printf 'debian' ;;
    *" fedora "*|*" rhel "*) printf 'fedora' ;;
    *" opensuse "*|*" suse "*) printf 'opensuse' ;;
    *) die "unsupported distribution: ${ID:-unknown}" ;;
  esac
}

print_command() {
  printf 'DRY-RUN:'
  printf ' %q' "$@"
  printf '\n'
}

run_root() {
  if ((DRY_RUN)); then
    print_command sudo "$@"
    return
  fi
  if ((EUID == 0)); then
    "$@"
  else
    have sudo || die "sudo is required"
    sudo "$@"
  fi
}

package_owner() {
  local distro="$1" path="$2"
  [[ -e "$path" || -L "$path" ]] || return 1
  case "$distro" in
    arch) pacman -Qo "$path" 2>/dev/null ;;
    debian) dpkg-query -S "$path" 2>/dev/null ;;
    fedora|opensuse) rpm -qf "$path" 2>/dev/null ;;
  esac
}

install_packages() {
  local distro="$1"
  info "Installing SOF firmware, ALSA UCM, test tools, PipeWire, and WirePlumber"
  case "$distro" in
    arch)
      run_root pacman -S --needed sof-firmware alsa-ucm-conf alsa-utils pipewire pipewire-audio wireplumber
      ;;
    debian)
      run_root apt-get update
      run_root apt-get install firmware-sof-signed alsa-ucm-conf alsa-utils pipewire wireplumber
      ;;
    fedora)
      run_root dnf install alsa-sof-firmware alsa-ucm alsa-utils pipewire wireplumber
      ;;
    opensuse)
      run_root zypper --non-interactive install sof-firmware alsa-ucm-conf alsa-utils pipewire wireplumber
      ;;
  esac
}

make_backup() {
  local stamp backup
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="${STATE_ROOT}/backup-${stamp}"
  LAST_BACKUP="$backup"
  info "Creating backup at ${backup}"
  run_root mkdir -p "$backup"

  if [[ -e "$STALE_TOPOLOGY" || -L "$STALE_TOPOLOGY" ]]; then
    run_root cp -a "$STALE_TOPOLOGY" "${backup}/sof-ptl-rt721-2ch.tplg"
    run_root sh -c "printf '%s\n' 'TOPOLOGY_EXISTED=1' > '$backup/state'"
  else
    run_root sh -c "printf '%s\n' 'TOPOLOGY_EXISTED=0' > '$backup/state'"
  fi

  if [[ -e "$COMBINED_UCM" || -L "$COMBINED_UCM" ]]; then
    run_root cp -a "$COMBINED_UCM" "${backup}/rt721+rt1320-init.conf"
    run_root sh -c "printf '%s\n' 'UCM_EXISTED=1' >> '$backup/state'"
  else
    run_root sh -c "printf '%s\n' 'UCM_EXISTED=0' >> '$backup/state'"
  fi

}

apply_fix() {
  local distro="$1" owner="" current=""

  if [[ -e "$STALE_TOPOLOGY" || -L "$STALE_TOPOLOGY" ]]; then
    owner="$(package_owner "$distro" "$STALE_TOPOLOGY" || true)"
    if [[ -n "$owner" ]]; then
      warn "Leaving package-owned topology untouched: ${owner}"
    else
      info "Removing stale, unowned topology that overrides packaged firmware"
      run_root rm -- "$STALE_TOPOLOGY"
      TOPOLOGY_CHANGED=1
    fi
  else
    info "No stale uncompressed 2-channel topology found"
  fi

  if ((DRY_RUN == 0)); then
    [[ -r "$RT721_UCM" ]] || die "missing ${RT721_UCM}; update alsa-ucm-conf/alsa-ucm first"
    [[ -r "$RT1320_UCM" ]] || die "missing ${RT1320_UCM}; update alsa-ucm-conf/alsa-ucm first"
  fi

  if [[ -r "$COMBINED_UCM" ]]; then
    current="$(<"$COMBINED_UCM")"
    if [[ "$current" == "$EXPECTED_UCM" ]]; then
      info "Combined RT721+RT1320 UCM initialization is already installed"
      return
    fi
    owner="$(package_owner "$distro" "$COMBINED_UCM" || true)"
    if [[ -n "$owner" ]]; then
      warn "A package-owned combined UCM file already exists; leaving it untouched: ${owner}"
      return
    fi
    die "${COMBINED_UCM} exists with different unowned content; inspect it or restore it before retrying"
  fi

  info "Installing combined RT721+RT1320 UCM initialization"
  if ((DRY_RUN)); then
    print_command sudo install -d -m 755 "${COMBINED_UCM%/*}"
    printf 'DRY-RUN: write %s\n' "$COMBINED_UCM"
  else
    local tmp
    tmp="$(mktemp)"
    printf '%s\n' "$EXPECTED_UCM" >"$tmp"
    run_root install -d -m 755 "${COMBINED_UCM%/*}"
    run_root install -m 644 "$tmp" "$COMBINED_UCM"
    rm -f "$tmp"
  fi
}

restart_audio_services() {
  if ((DRY_RUN)); then
    print_command systemctl --user restart wireplumber pipewire pipewire-pulse
    return
  fi
  if have systemctl; then
    systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null ||
      warn "Could not restart all user audio services; log out or reboot"
  fi
}

diagnose() {
  local product distro
  product="$(read_product)"
  distro="$(detect_distro)"
  cat <<EOF
Product:      ${product}
Kernel:       $(uname -r)
Distribution: ${distro}
EOF

  printf '\nPCI audio controllers:\n'
  if have lspci; then
    lspci -nnk | awk 'BEGIN{IGNORECASE=1} /audio|multimedia/{show=5} show>0{print; show--}'
  else
    printf 'lspci is not installed\n'
  fi

  printf '\nSoundWire devices:\n'
  local found=0 device
  shopt -s nullglob
  for device in /sys/bus/soundwire/devices/*; do
    found=1
    printf '%s\n' "${device##*/}"
  done
  shopt -u nullglob
  ((found)) || printf 'none detected\n'

  printf '\nRelevant files:\n'
  for device in "$STALE_TOPOLOGY" "${STALE_TOPOLOGY}.xz" "$RT721_UCM" "$RT1320_UCM" "$COMBINED_UCM"; do
    if [[ -e "$device" || -L "$device" ]]; then
      printf 'present  %s' "$device"
      package_owner "$distro" "$device" 2>/dev/null | sed 's/^/  owner: /' || printf '  owner: unowned\n'
    else
      printf 'missing  %s\n' "$device"
    fi
  done

  printf '\nALSA cards and playback devices:\n'
  if have aplay; then
    aplay -l 2>&1 || true
  else
    printf 'aplay is not installed\n'
  fi

  printf '\nPipeWire/WirePlumber status:\n'
  if have wpctl; then
    wpctl status 2>&1 || true
  else
    printf 'wpctl is not installed\n'
  fi

  printf '\nRecent kernel audio messages:\n'
  if have journalctl; then
    journalctl -b -k --no-pager 2>/dev/null |
      awk 'BEGIN{IGNORECASE=1} /sof|soundwire|snd|audio|codec|rt721|rt1320/'
  else
    printf 'journalctl is not installed\n'
  fi
}

prompt_yes_no() {
  local prompt="$1" answer
  [[ -t 0 ]] || return 1
  read -r -p "${prompt} [y/N] " answer
  [[ "$answer" == [Yy] || "$answer" == [Yy][Ee][Ss] ]]
}

test_audio() {
  have aplay || die "aplay is required; install alsa-utils"
  have speaker-test || die "speaker-test is required; install alsa-utils"

  printf 'Available ALSA playback devices:\n'
  aplay -l
  printf '\nUse the card and device numbers shown above (for example, 1,2).\n'

  local label pcm
  for label in "laptop speakers" "USB-C/HDMI monitor"; do
    if ! prompt_yes_no "Run a bounded stereo test on the ${label}?"; then
      info "Skipping ${label} test"
      continue
    fi
    read -r -p "Enter card,device for ${label}: " pcm
    [[ "$pcm" =~ ^[0-9]+,[0-9]+$ ]] || die "invalid PCM '${pcm}'; expected card,device"
    info "Testing ${label} through hw:${pcm}; two channel announcements/tones should play"
    speaker-test -D "hw:${pcm}" -c 2 -r 48000 -F S32_LE -t sine -l 1
  done
}

restore_latest() {
  local backups=() backup state topology_existed=0 ucm_existed=0
  shopt -s nullglob
  backups=("${STATE_ROOT}"/backup-*)
  shopt -u nullglob
  ((${#backups[@]})) || die "no backup found under ${STATE_ROOT}"
  backup="${backups[${#backups[@]}-1]}"
  state="${backup}/state"
  [[ -r "$state" ]] || die "backup state is missing: ${state}"

  # The state file is generated internally and contains only 0/1 assignments.
  # shellcheck disable=SC1090
  source "$state"
  topology_existed="${TOPOLOGY_EXISTED:-0}"
  ucm_existed="${UCM_EXISTED:-0}"
  info "Restoring ${backup}"

  if [[ "$topology_existed" == 1 ]]; then
    run_root install -D -m 644 "${backup}/sof-ptl-rt721-2ch.tplg" "$STALE_TOPOLOGY"
  fi
  if [[ "$ucm_existed" == 1 ]]; then
    run_root install -D -m 644 "${backup}/rt721+rt1320-init.conf" "$COMBINED_UCM"
  elif [[ -r "$COMBINED_UCM" ]] && [[ "$(<"$COMBINED_UCM")" == "$EXPECTED_UCM" ]]; then
    run_root rm -- "$COMBINED_UCM"
  fi
  restart_audio_services
  warn "Reboot if a topology file was restored"
}

install_fix() {
  local product distro
  product="$(read_product)"
  if [[ "$product" != "$SUPPORTED_PRODUCT" ]] && ((FORCE_MODEL == 0)); then
    die "unsupported product '${product}'; expected '${SUPPORTED_PRODUCT}'"
  fi
  if [[ "$product" != "$SUPPORTED_PRODUCT" ]]; then
    warn "Model check overridden; this fix may damage audio configuration"
  fi

  distro="$(detect_distro)"
  info "Detected distribution family: ${distro}"
  make_backup
  install_packages "$distro"
  apply_fix "$distro"
  restart_audio_services
  info "Repair complete; backup: ${LAST_BACKUP}"
  if ((TOPOLOGY_CHANGED)); then
    warn "Reboot is required because the stale topology was removed"
  fi
  if prompt_yes_no "Run prompted speaker tests now?"; then
    test_audio
  fi
}

case "$ACTION" in
  diagnose) diagnose ;;
  install) install_fix ;;
  test) test_audio ;;
  restore) restore_latest ;;
esac
