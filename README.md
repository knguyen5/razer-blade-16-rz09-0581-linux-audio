# Razer Blade 16 RZ09-0581 Linux audio fix

Repair and diagnostic tooling for the 2026 Razer Blade 16 model
`Blade 16 - RZ09-0581` (board `SO6120`) with:

- Intel Panther Lake Sound Open Firmware (SOF)
- Realtek RT721 SoundWire headset codec
- Realtek RT1320 SoundWire speaker amplifier

> [!WARNING]
> This repair was developed and tested on **CachyOS** with
> `linux-cachyos 7.1.6`. The Debian/Ubuntu, Fedora, and openSUSE paths are
> best-effort package-manager adaptations and have not been tested on those
> distributions. They may require a newer kernel, SOF firmware, or ALSA UCM
> package than the distribution currently provides. Read the diagnostics and
> backup instructions before applying the fix.

## Symptoms

- The internal speakers are present but silent, or the entire SOF audio card
  fails to appear.
- Audio from a USB-C-connected monitor is unavailable even though it works in
  Windows.
- Executing an ALC298 `hda-verb` workaround may create a device, but no sound
  plays.
- Kernel logs can contain topology component-load or card-instantiation
  failures involving `sof-ptl-rt721-2ch.tplg`.

The ALC298 workaround for older Blade 16 models does **not** apply here. This
model uses RT721 and RT1320 codecs over SoundWire rather than an ALC298 HDA
codec.

## Why it happens

Two separate faults were observed:

1. An unowned, incompatible
   `/usr/lib/firmware/intel/sof-ipc4-tplg/sof-ptl-rt721-2ch.tplg` overrode the
   packaged Panther Lake topology. The kernel could not instantiate the
   `sof-soundwire` card, so neither the internal speaker PCM nor the monitor
   HDMI PCM was exposed.
2. Once the kernel card loaded, the installed ALSA UCM data had individual
   initialization files for RT721 and RT1320, but lacked the combined
   `codecs/rt721+rt1320/init.conf`. The RT1320 amplifier routing remained
   uninitialized, leaving the internal speakers silent.

The verified system required Linux 7.1 for Panther Lake/SoundWire support. The
tested CachyOS 6.18 LTS kernel did not provide the required working topology for
this laptop.

## Automated repair

Inspect the script before running it:

```bash
less ./razer-audio-fix.sh
```

Collect read-only diagnostics:

```bash
./razer-audio-fix.sh diagnose | tee razer-audio-diagnostics.log
```

Preview changes for the detected distribution:

```bash
./razer-audio-fix.sh install --dry-run
```

Apply the fix:

```bash
./razer-audio-fix.sh install
```

The script:

- verifies the exact DMI model by default;
- installs firmware, UCM, ALSA test, PipeWire, and WirePlumber packages through
  the native package manager;
- creates a timestamped backup under `/var/lib/razer-audio-fix`;
- removes the problematic topology only if it is unowned by the package
  manager;
- never overwrites a package-owned combined UCM file;
- installs the missing combined UCM initialization when needed; and
- asks before emitting any speaker-test sound.

Other actions:

```bash
./razer-audio-fix.sh test
./razer-audio-fix.sh restore
./razer-audio-fix.sh --help
```

Use `--distro arch|debian|fedora|opensuse` only to override failed
distribution detection. `--force-unsupported-model` bypasses the hardware
guard and is intentionally not recommended.

After a topology change, reboot and verify:

```bash
uname -r
aplay -l
wpctl status
```

A working system should expose a `sof-soundwire` card with a `Speaker` PCM and
one or more HDMI PCMs.

## Manual repair

### 1. Confirm the hardware

```bash
cat /sys/class/dmi/id/product_name
uname -r
aplay -l
sudo journalctl -b -k --no-pager |
  grep -Ei 'sof|soundwire|audio|codec|rt721|rt1320'
```

Continue only if the product is `Blade 16 - RZ09-0581`. Use a kernel new enough
to support Panther Lake SOF/SoundWire; Linux 7.1.6 was verified.

### 2. Install distribution packages

Arch Linux and CachyOS:

```bash
sudo pacman -S --needed \
  sof-firmware alsa-ucm-conf alsa-utils \
  pipewire pipewire-audio wireplumber
```

Debian and Ubuntu:

```bash
sudo apt update
sudo apt install \
  firmware-sof-signed alsa-ucm-conf alsa-utils \
  pipewire wireplumber
```

Fedora:

```bash
sudo dnf install \
  alsa-sof-firmware alsa-ucm alsa-utils \
  pipewire wireplumber
```

openSUSE Tumbleweed:

```bash
sudo zypper install \
  sof-firmware alsa-ucm-conf alsa-utils \
  pipewire wireplumber
```

Older stable distributions may not carry sufficiently new Panther Lake
firmware or UCM data. Do not download random firmware blobs to work around an
old repository; use a supported update/backport source for that distribution.

### 3. Back up and check the suspect topology

```bash
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
sudo mkdir -p "/var/lib/razer-audio-fix/manual-${stamp}"
sudo cp -a /usr/lib/firmware/intel/sof-ipc4-tplg \
  "/var/lib/razer-audio-fix/manual-${stamp}/"
sudo cp -a /usr/share/alsa/ucm2 \
  "/var/lib/razer-audio-fix/manual-${stamp}/"
```

Check whether the raw 2-channel topology is package-owned.

Arch/CachyOS:

```bash
pacman -Qo \
  /usr/lib/firmware/intel/sof-ipc4-tplg/sof-ptl-rt721-2ch.tplg
```

Debian/Ubuntu:

```bash
dpkg-query -S \
  /usr/lib/firmware/intel/sof-ipc4-tplg/sof-ptl-rt721-2ch.tplg
```

Fedora/openSUSE:

```bash
rpm -qf \
  /usr/lib/firmware/intel/sof-ipc4-tplg/sof-ptl-rt721-2ch.tplg
```

Only if the file exists **and** the package manager reports that no package
owns it, remove it:

```bash
sudo rm -- \
  /usr/lib/firmware/intel/sof-ipc4-tplg/sof-ptl-rt721-2ch.tplg
```

Never remove a package-owned topology. Reinstall/update the owning firmware
package instead.

### 4. Add the combined UCM initialization

Confirm both source files exist:

```bash
test -r /usr/share/alsa/ucm2/codecs/rt721/init.conf
test -r /usr/share/alsa/ucm2/codecs/rt1320/init.conf
```

If `/usr/share/alsa/ucm2/codecs/rt721+rt1320/init.conf` is already
package-owned, leave it untouched. Otherwise create it:

```bash
sudo install -d -m 755 \
  /usr/share/alsa/ucm2/codecs/rt721+rt1320

sudo tee /usr/share/alsa/ucm2/codecs/rt721+rt1320/init.conf >/dev/null <<'EOF'
# Combined RT721 headset codec and RT1320 speaker amplifier initialization.

Include.rt721.File "/codecs/rt721/init.conf"
Include.rt1320.File "/codecs/rt1320/init.conf"
EOF
```

Restart the user audio services:

```bash
systemctl --user restart wireplumber pipewire pipewire-pulse
```

Reboot if the topology file was removed.

### 5. Test only after confirmation

List devices:

```bash
aplay -l
```

Find the `sof-soundwire` card and its `Speaker` device. After warning anyone
near the laptop and checking volume, run one bounded test, replacing `CARD` and
`DEVICE`:

```bash
speaker-test -D hw:CARD,DEVICE -c 2 -r 48000 -F S32_LE -t sine -l 1
```

Repeat only after confirming the USB-C/HDMI monitor PCM shown by `aplay -l`.
On the verified machine, the devices were `hw:1,2` (speakers) and `hw:1,5`
(AORUS monitor), but ALSA card numbers are not stable and must not be copied
blindly.

## Rollback

The automated installer records the previous state:

```bash
./razer-audio-fix.sh restore
```

For a manual repair, copy the backed-up files from
`/var/lib/razer-audio-fix/manual-TIMESTAMP/` to their original paths. Remove
the custom combined UCM file only if it did not exist before the repair.

## Troubleshooting

Generate a report:

```bash
./razer-audio-fix.sh diagnose >razer-audio-diagnostics.log 2>&1
```

Useful checks:

```bash
aplay -l
arecord -l
wpctl status
systemctl --user status wireplumber pipewire pipewire-pulse
sudo journalctl -b -k --no-pager |
  grep -Ei 'sof|soundwire|snd|audio|codec|rt721|rt1320'
```

If no `sof-soundwire` card appears, resolve the kernel/firmware/topology
failure before changing PipeWire settings. If the card and speaker PCM appear
but remain silent, inspect UCM loading and mixer controls.
