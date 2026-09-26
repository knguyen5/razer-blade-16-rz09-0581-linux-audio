#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly KREL="${KREL_OVERRIDE:-$(pacman -Q linux-cachyos-lts | awk '{print $2 "-cachyos-lts"}')}"
readonly RESOLVED_PACKAGE_VERSION="${KREL%-cachyos-lts}"
readonly WORK_BASE="${WORK_ROOT_OVERRIDE:-${ROOT_DIR}/work}"
readonly WORK_DIR="${WORK_BASE}/${KREL}"
readonly PACKAGING_DIR="${WORK_DIR}/linux-cachyos"
readonly PACKAGE_DIR="${PACKAGING_DIR}/linux-cachyos-lts"
readonly SOURCE_ROOT="${PACKAGE_DIR}/src/cachyos-${RESOLVED_PACKAGE_VERSION}"
readonly KBUILD_DIR="/usr/lib/modules/${KREL}/build"
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
readonly -a UPSTREAM_COMMITS=(
  2b92b98cc4765fbb0748742e7e0dd94d15d6f178
  d25de16477657f9eddd4be9abd409515edcc3b9e
  ea97713903784286ef1ce45456f404ed288f19b1
  7196fc4e482928a276da853e2687f31cd8ea2611
  5ed60e45c59d66e61586a10433e2b5527d4d72b5
  6937ff42f28a13ffdbe2d1f5b9a51a35f626e93a
  99c159279c6dfa2c4867c7f76875f58263f8f43b
  5226d19d4cae5398caeb93a6052bfb614e0099c7
  5cd5f8fc29fa1b6d7c0a8f2b0a95b896ecadfa42
  284e70ace9ecdeb8644fbe65c5da12c90b377545
  bb6a3c2db281c7d5aaa79b2a6fa00bcd10c0bb8f
  86facd80a2a37536937f06de637abf9e8cabdb4b
  1de6ddcddc954a69f96b1c23205e03ddd603e3c8
  3c6f06a200796ae7b2b1065e8a6499b138e27a50
)

for command_name in git curl make makepkg patch bc modinfo; do
  command -v "$command_name" >/dev/null || {
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  }
done

[[ "$RESOLVED_PACKAGE_VERSION" == 6.18.*-* ]] || {
  printf 'Unsupported LTS package version: %s\n' "$RESOLVED_PACKAGE_VERSION" >&2
  printf 'Test the stock kernel before extending this 6.18-only backport.\n' >&2
  exit 1
}

[[ -r "${KBUILD_DIR}/.config" && -r "${KBUILD_DIR}/Module.symvers" ]] || {
  printf 'Install linux-cachyos-lts-headers %s before building.\n' "$KREL" >&2
  exit 1
}

# Ftrace call-site layout must match the compiler used for the stock kernel.
make_flags=("-j$(nproc)")
if grep -qx 'CONFIG_CC_IS_CLANG=y' "${KBUILD_DIR}/.config"; then
  for command_name in clang ld.lld llvm-ar; do
    command -v "$command_name" >/dev/null || {
      printf 'Missing required command: %s\n' "$command_name" >&2
      exit 1
    }
  done
  make_flags=(LLVM=1 LLVM_IAS=1 "-j$(nproc)")
else
  command -v gcc >/dev/null || {
    printf 'Missing required command: gcc\n' >&2
    exit 1
  }
fi

mkdir -p "$WORK_DIR" "${WORK_DIR}/downloads"
if [[ ! -d "${PACKAGING_DIR}/.git" ]]; then
  git clone --filter=blob:none https://github.com/CachyOS/linux-cachyos.git "$PACKAGING_DIR"
fi
git -C "$PACKAGING_DIR" fetch --filter=blob:none origin master

package_commit=""
while IFS= read -r candidate; do
  pkgbuild="$(git -C "$PACKAGING_DIR" show "${candidate}:linux-cachyos-lts/PKGBUILD")"
  major="$(awk -F= '/^_major=/{print $2; exit}' <<<"$pkgbuild")"
  minor="$(awk -F= '/^_minor=/{print $2; exit}' <<<"$pkgbuild")"
  release="$(awk -F= '/^pkgrel=/{print $2; exit}' <<<"$pkgbuild")"
  if [[ "${major}.${minor}-${release}" == "$RESOLVED_PACKAGE_VERSION" ]]; then
    package_commit="$candidate"
    break
  fi
done < <(git -C "$PACKAGING_DIR" rev-list origin/master -- linux-cachyos-lts/PKGBUILD)

[[ -n "$package_commit" ]] || {
  printf 'No CachyOS packaging commit matches %s.\n' "$RESOLVED_PACKAGE_VERSION" >&2
  exit 1
}
git -C "$PACKAGING_DIR" checkout --detach "$package_commit"

if [[ ! -d "$SOURCE_ROOT" ]]; then
  (
    cd "$PACKAGE_DIR"
    makepkg --nobuild --nodeps --noconfirm --skippgpcheck
  )
fi

if [[ ! -e "${SOURCE_ROOT}/.razer-backport-applied" ]]; then
  patch -d "$SOURCE_ROOT" -Np1 <"${ROOT_DIR}/patches/rt721-function-topology.patch"

  for commit in "${UPSTREAM_COMMITS[@]}"; do
    patch_file="${WORK_DIR}/downloads/${commit}.patch"
    curl -fsSL "https://github.com/torvalds/linux/commit/${commit}.patch" -o "$patch_file"
    patch -d "$SOURCE_ROOT" -Np1 <"$patch_file"
  done

  patch -d "$SOURCE_ROOT" -Np1 <"${ROOT_DIR}/patches/sof-intel-desc-abi.patch"
  touch "${SOURCE_ROOT}/.razer-backport-applied"
fi

cp -- "${KBUILD_DIR}/.config" "${SOURCE_ROOT}/.config"
cp -- "${KBUILD_DIR}/Module.symvers" "${SOURCE_ROOT}/Module.symvers"

make -C "$SOURCE_ROOT" "${make_flags[@]}" olddefconfig prepare modules_prepare
for module_dir in sound/soc/sdw_utils sound/soc/intel/common sound/soc/sof sound/soc/intel/boards; do
  make -C "$SOURCE_ROOT" "${make_flags[@]}" M="$module_dir" clean
done
make -C "$SOURCE_ROOT" "${make_flags[@]}" M=sound/soc/sdw_utils modules
make -C "$SOURCE_ROOT" "${make_flags[@]}" M=sound/soc/intel/common modules

extra_symbols="${SOURCE_ROOT}/sound/soc/intel/common/Module.symvers"
extra_symbols+=" ${SOURCE_ROOT}/sound/soc/sdw_utils/Module.symvers"
make -C "$SOURCE_ROOT" "${make_flags[@]}" M=sound/soc/sof \
  KBUILD_EXTRA_SYMBOLS="$extra_symbols" modules
make -C "$SOURCE_ROOT" "${make_flags[@]}" M=sound/soc/intel/boards \
  KBUILD_EXTRA_SYMBOLS="$extra_symbols" modules

for relative_module in "${BUILT_MODULES[@]}"; do
  module="${SOURCE_ROOT}/${relative_module}"
  vermagic="$(modinfo -F vermagic "$module")"
  [[ "$vermagic" == "${KREL} "* ]] || {
    printf 'Wrong vermagic for %s: %s\n' "$module" "$vermagic" >&2
    exit 1
  }
done

printf 'Build complete for %s.\nRun: sudo %s/install.sh\n' "$KREL" "$ROOT_DIR"
