# ASUS ProArt PX13 (HN7306) — Internal Speakers on Linux

Tested on **Omarchy / Arch Linux**, kernel **7.0.0+ mainline** (the AMD ACP70 PX13 quirks landed in mainline 2026-03-16 and ship in 7.0). Distro-specific steps for **Fedora 44** are called out inline below — the script itself is distro-agnostic; only the package install and kernel steps differ.

This was the first publicly-confirmed working speaker setup for this laptop — kernel side worked out of the box on 7.0, but the TAS2783 SmartAmp speaker calibration blobs are not yet in `linux-firmware`. They ship in the official ASUS Windows driver. [`extract-px13-tas2783-fw.sh`](extract-px13-tas2783-fw.sh) extracts your own copy, installs it, and configures WirePlumber.

If you're hitting `slave-tas2783 ... Direct firmware load for ... failed with error -2` in dmesg (the requested filename is `1714-1-0x8.bin` on kernel **7.1+**, or `1714-1-8.bin` on **7.0** — see [Why this is needed](#why-this-is-needed)) and `wpctl status` shows only **Dummy Output**, this is for you.

---

## Prerequisites

- Linux 7.0 mainline. Stock `linux 6.19.x` does **not** have the ACP70 PX13 quirks; you'll see only an `acp-pdm-mach` capture-only card.
  - **Arch:** AUR `linux-mainline` package.
  - **Fedora 44:** run `uname -r` first — if the stock kernel is already ≥ 7.0 you're done. Otherwise pull a mainline build from the community COPR:
    ```bash
    sudo dnf copr enable @kernel-vanilla/mainline
    sudo dnf update kernel\* --refresh
    ```
    (Fedora 44 ships a 6.2x kernel at GA; the 7.0 quirks arrive via a later stable update or the COPR above. Reboot into the new kernel before continuing.)
- Set the right Strix Halo kernel cmdline (optional but recommended): `iommu=pt amdgpu.gttsize=126976 ttm.pages_limit=32505856` (raises GTT to ~124 GiB for unified memory).
  - **Arch:** add to your bootloader entry / `linux.conf`.
  - **Fedora 44:** apply persistently with grubby, then reboot:
    ```bash
    sudo grubby --update-kernel=ALL --args="iommu=pt amdgpu.gttsize=126976 ttm.pages_limit=32505856"
    ```

## Required tools

**Arch:**

```bash
sudo pacman -S 7zip wine inotify-tools
```

`p7zip` from extra was renamed to `7zip` in current Arch.

**Fedora 44:**

```bash
sudo dnf install 7zip wine inotify-tools rsync
```

Notes:
- `7zip` (upstream 7-Zip, provides `7z`/`7zz`) is in Fedora's main repos as of F41 — no RPM Fusion needed. The script doesn't actually shell out to 7-Zip (it uses `wine`), so this is only for manual poking.
- `wine` comes straight from the Fedora repos.
- `rsync` and `curl` may already be present, but Fedora minimal installs can lack `rsync`, and the script relies on it — install it explicitly. `curl` ships as `curl-minimal` by default and is sufficient.

## Usage

```bash
git clone https://github.com/l1a/asus-px13-tas2783.git
cd asus-px13-tas2783
./extract-px13-tas2783-fw.sh
sudo reboot
```

Run it as your normal user (**not** with `sudo` — it elevates itself only where needed, and the WirePlumber config must land in *your* home directory).

The script does everything in one pass:

1. **Gets the firmware blobs** — downloads the official ASUS TI SmartAmp DCH driver and extracts them via wine. If the blobs are already sitting **next to the script** (either as `1714-1-0x8.bin` / `1714-1-0xB.bin`, the names the ASUS driver ships, or as `1714-1-8.bin` / `1714-1-B.bin`), it reuses them and skips the download/extraction entirely — handy for re-running, or for machines without wine/network access.
2. **Installs them to `/lib/firmware/`** under *both* the `0x`-prefixed and de-prefixed names (and in `ti/audio/tas2783/`), so the load is clean on kernel 7.0 and 7.1+ alike.
3. **Relabels for SELinux** (`restorecon`) automatically on systems that have it (Fedora et al.) — a no-op on Arch.
4. **Writes the WirePlumber config** (`~/.config/wireplumber/wireplumber.conf.d/51-strix-halo-audio.conf`, contents below) and restarts WirePlumber/PipeWire. The speaker sink only appears after the post-install reboot; the config persists, so after rebooting the speakers come up and win the default-sink election by priority.

After the reboot, verify:

```bash
dmesg | grep tas2783    # should NOT show 'Direct firmware load for 1714-1-* failed'
pw-cat --target=alsa_output.pci-0000_c4_00.5-platform-amd_sdw.pro-output-2 \
       --playback /usr/share/sounds/alsa/Front_Center.wav
```

### Fedora 44 notes

The script runs unchanged on Fedora 44 — `/lib/firmware` is a symlink to `/usr/lib/firmware` (merged-usr), so the target paths resolve correctly, and the SELinux relabel is handled automatically (step 3 above).

If firmware still fails to load after reboot, confirm it isn't SELinux by checking `sudo ausearch -m avc -ts recent | grep -i firmware` — a denial there means the relabel didn't take (re-run `sudo restorecon -Rv /usr/lib/firmware`). As a diagnostic only (not a fix), you can `sudo setenforce 0`, retest, then re-enable with `sudo setenforce 1` and relabel properly.

## What the WirePlumber config does

PipeWire's auto-profile for this card is `off` because UCM doesn't expose a "Speakers" port. The config the script writes forces the `pro-audio` profile, names the speaker sink, disables its suspend (prevents most SoundWire desyncs), and raises its session priority so it becomes the default sink:

```
monitor.alsa.rules = [
  {
    matches = [
      { device.name = "alsa_card.pci-0000_c4_00.5-platform-amd_sdw" }
    ]
    actions = {
      update-props = {
        device.profile = "pro-audio"
      }
    }
  }
  {
    matches = [
      { node.name = "alsa_output.pci-0000_c4_00.5-platform-amd_sdw.pro-output-2" }
    ]
    actions = {
      update-props = {
        session.suspend-timeout-seconds = 0
        node.description = "Internal Speakers (TAS2783)"
        priority.session = 2000
      }
    }
  }
]
```

If the speakers don't become the default sink on their own, pin them manually:

```bash
pactl set-default-sink alsa_output.pci-0000_c4_00.5-platform-amd_sdw.pro-output-2
```

## Recovery if speakers desync (occasional)

The SoundWire bus sometimes loses sync after suspend or long idle. Quick fix without reboot:

```bash
pactl set-card-profile alsa_card.pci-0000_c4_00.5-platform-amd_sdw off
sleep 1
pactl set-card-profile alsa_card.pci-0000_c4_00.5-platform-amd_sdw pro-audio
```

The `session.suspend-timeout-seconds = 0` rule above prevents most occurrences.

## What's working / not working

| | Status |
|---|---|
| Internal speakers (TAS2783) | ✅ Working |
| 3.5mm headphone jack (RT721 SDCA) | ✅ Working (separate sink, `pro-output-0`) |
| HDMI audio | ✅ Working |
| Bluetooth audio | ✅ Working |
| Headphone jack auto-switch on plug-in | ❌ Manual sink switch needed |
| Microphone (PDM array) | ⚠️ Not tested |

## Why this is needed

- Linux's `slave-tas2783` driver (`sound/soc/codecs/tas2783-sdw.c`) calls `request_firmware_nowait()` for a name built from the subsystem ID, SoundWire link, and slave address. With ASUS subsystem ID `0x1714`, link 1, and addresses 0x8 / 0xB:
  - **Kernel 7.0** used `%04X-%1X-%1X.bin` → `1714-1-8.bin`, `1714-1-B.bin`.
  - **Kernel 7.1+** changed this to `%04X-%1X-%s%1X.bin` with a `0x` prefix and a fallback: it requests `1714-1-0x8.bin` **first**, and only on failure falls back to the de-prefixed `1714-1-8.bin`. (See `tas_generate_fw_name()` / `fw_use_fallback` in the driver.) That's why the script installs **both** names — the 0x-prefixed one loads cleanly on 7.1+ (no failed-load line in dmesg), and the de-prefixed one covers 7.0 and the 7.1+ fallback.
- `linux-firmware` ships TAS2783 blobs only for HP/Dell systems (subsystem IDs `0x8E86`, `0x8E87`, `0x8EF5`, `0x8EF6`). No ASUS blobs upstream as of 2026-04-25 (still absent as of kernel 7.2 / `linux-firmware` `main`).
- The blobs are device-specific calibration/protection data programmed by ASUS at the factory. They're shipped in the Windows DCH driver under `Firmwares/<subsysID>-<link>-0x<addr>.bin`.

## References

- CachyOS issue documenting same hardware: https://github.com/CachyOS/linux-cachyos/issues/737
- Mainline ACP70 PX13 patch series (Mark Brown, 2026-03-16): https://lkml.org/lkml/2026/3/16/1730
- Driver source: https://github.com/torvalds/linux/blob/master/sound/soc/codecs/tas2783-sdw.c

---

*Contributed by a Linux user who got tired of using bluetooth headphones. If you have working firmware blobs for related ASUS models (subsystem IDs near 0x1714), please open an MR against linux-firmware.*
