# CachyOS 6.18.42 LTS backport

This backport enables the RT721 + RT1320 SoundWire function-topology path on
the Razer Blade 16 RZ09-0581 while retaining the kernel used for game
stability.

> [!CAUTION]
> This is an exact-version developer backport for
> `6.18.42-1-cachyos-lts`. It is not a portable driver package. The modules are
> unsigned and taint the kernel. Secure Boot configurations that enforce module
> signatures will reject them.

## Cause

The 6.18 kernel contains the function-topology loader, but Panther Lake still
selects a monolithic RT721 match entry. Removing that entry with upstream
commit [`754b3dade5dd`](https://github.com/torvalds/linux/commit/754b3dade5ddbfd849e6ca9864cef45ce34cd7f6)
is necessary but not sufficient: 6.18 also predates the default SoundWire
machine-construction series beginning with
[`5226d19d4cae`](https://github.com/torvalds/linux/commit/5226d19d4cae5398caeb93a6052bfb614e0099c7).

Without the complete backport, the kernel either:

- falls back to `skl_hda_dsp_generic`, exposing only HDMI and DMIC devices; or
- requests the obsolete `sof-ptl-rt721-2ch.tplg`, which cannot represent both
  the RT721 and RT1320 functions on SoundWire link 3.

The backport removes the obsolete match, dynamically constructs the `sof_sdw`
machine, and loads separate jack, amplifier, DMIC, and HDMI function
topologies. The upstream descriptor change is adapted by placing its new field
at the end of the 6.18 structure, preserving compatibility with stock SOF
modules not replaced by this package.

## Verified result

Tested on CachyOS, Razer `Blade 16 - RZ09-0581`, kernel
`6.18.42-1-cachyos-lts`, SOF firmware `2.14.1.1`:

- kernel log reports `Use SoundWire default machine driver with function topologies`;
- RT721 jack, RT1320 amplifier, DMIC, and HDMI topology fragments load;
- ALSA exposes `sof-soundwire` Speaker, Headset, DMIC, and HDMI PCMs;
- bounded left/right tests pass on the laptop speakers and USB-C monitor; and
- Elden Ring Nightreign remained stable in the post-backport LTS gameplay
  test that previously reproduced the 7.x-kernel crash.

The `Bus clash detected before INT mask is enabled` line was present during the
successful boot and did not prevent card creation or playback.

## Build and install

Install the matching CachyOS LTS kernel and headers plus normal Arch kernel
build tools. Review every script before running it.

```bash
cd lts-backport
./build.sh
sudo ./install.sh
```

Reboot into `6.18.42-1-cachyos-lts`, then verify before producing sound:

```bash
uname -r
sudo journalctl -b -k --no-pager |
  grep -Ei 'function topolog|rt721|rt1320|sof-soundwire'
aplay -l
wpctl status
```

The build script:

1. checks out CachyOS packaging commit `12d9925010ab`;
2. prepares the exact 6.18.42 CachyOS source and configuration;
3. applies the RT721 match removal, default SoundWire series, fixes, and the
   ABI-safe descriptor adjustment;
4. builds only the affected audio modules; and
5. verifies every module's vermagic.

The installer refuses other laptop models, backs up package modules and the
LTS initramfs, installs overrides under
`/usr/lib/modules/6.18.42-1-cachyos-lts/updates/razer/`, runs `depmod`, and
regenerates only the CachyOS LTS initramfs.

## Rollback

```bash
sudo ./rollback.sh
```

Reboot after rollback. Other installed kernels are not modified.

## Kernel update warning

Kernel modules are tied to an exact kernel ABI. After every
`linux-cachyos-lts` update:

1. do not reuse these old module binaries;
2. check whether the new kernel already logs successful function-topology
   selection without overrides;
3. if it does not, update the version guards and rebuild against the new
   package and headers; and
4. keep another bootable kernel available until audio is reverified.
