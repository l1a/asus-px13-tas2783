# TAS2783 Stereo Speakers + Internal DMIC on the ASUS ProArt PX13 (HN7306) under Linux

Working **true stereo** internal speakers (`TAS2783`), **internal digital microphone** (`acp-dmic`), **3.5mm headset jack** (`rt721-sdca`), and **suspend/resume (`s2idle`) recovery** on the ASUS ProArt PX13 (`HN7306EAC`, `HN7306EA`, AMD Strix Halo) — on **stock kernels ≥ 7.1** (`7.1`, `7.2`, and `7.3+`), including **Fedora 44+ with Secure Boot enabled (DKMS + MOK signing) and SELinux Enforcing**.

Based on **[ftoleedo/px13-audio-fix](https://github.com/ftoleedo/px13-audio-fix)** (commit `fd5cfaa`), with turn-key Fedora Secure Boot MOK enrollment, SELinux context enforcement, external/docked sink priority preservation, and a 1-command complete rollback script (`revert-px13-audio.sh`).

> **Why the older `pro-audio` + Windows firmware extraction approach was retired:**
> - `linux-firmware ≥ 20260519` already ships the official ASUS `1714-1-0x8.bin` and `1714-1-0xB.bin` SmartAmp calibration blobs in `/usr/lib/firmware/ti/audio/tas2783/` — Wine extraction is no longer needed.
> - Forcing `device.profile = "pro-audio"` in WirePlumber either plays mono from a single speaker (because both amps boot with DSP cluster index `0x01`) or creates a stalled audio clock that freezes browser video playback after `s2idle` resume.
> - Proper stereo + jack + DMIC integration requires the ALSA UCM `HiFi` profile plus the `tas2783-N Channel Playback` (`Left` / `Right`) SDCA cluster-index control provided by this repository's DKMS module.

---

## Quick Start — Fedora 44+ (with Secure Boot & SELinux Enforcing)

Run as your normal desktop user (**not** with `sudo` — the script prompts for `sudo` where needed while keeping your user PipeWire session intact):

```bash
git clone https://github.com/l1a/asus-px13-tas2783.git
cd asus-px13-tas2783

# 1. Pre-reboot setup: installs dkms/kernel-devel/alsa-ucm-utils, imports the DKMS
#    MOK key via mokutil, builds & signs the module, installs UCM + rt721 udev +
#    s2idle hook, restores SELinux contexts, and backs up WirePlumber state:
bash ./install-step1-pre-reboot.sh

# 2. Reboot and enroll the MOK key on the blue UEFI MokManager screen (one-time):
#    Enroll MOK -> Continue -> Yes -> <enter one-time password> -> Reboot
sudo reboot

# 3. Post-reboot verification + Left/Right speaker test:
bash ./verify-step2-post-reboot.sh
```

> **Note on LUKS2 TPM2 auto-unlock (PCR 7):** `shim` measures user-enrolled MOK keys into **PCR 14**, not PCR 7, so enrolling `/var/lib/dkms/mok.pub` keeps Secure Boot enabled without invalidating PCR 7 TPM2 disk unlock.

### One-Command Complete Rollback (Emergency or Routine)

If you ever want to revert 100% of the changes (safe to run from a graphical terminal or a `Ctrl+Alt+F3` TTY):

```bash
bash ./revert-px13-audio.sh --yes
# Optional: also remove the dkms and alsa-ucm-utils RPMs:
# bash ./revert-px13-audio.sh --yes --remove-packages
sudo reboot
```

---

## Quick Start — Arch / CachyOS / Generic Distros (or Secure Boot Disabled)

```bash
git clone https://github.com/l1a/asus-px13-tas2783.git
cd asus-px13-tas2783
bash install-durable.sh          # DKMS module + ALSA UCM + rt721 udev rule
bash install-resume-recovery.sh  # systemd-sleep s2idle recovery hook
```

To verify at any time (especially after a kernel or `alsa-ucm` package update):

```bash
bash check-audio.sh
```

---

## What Is Broken on Stock Kernels ≥ 7.1 and How This Repo Fixes It

TI upstreamed a new `tas2783` driver in Linux 7.1. On the ASUS ProArt PX13, three issues remain:

| # | Problem | Symptom | Fix in this repo |
|---|---------|---------|------------------|
| 1 | **On 7.1:** the machine driver does not tag the card with `spk:tas2783`, so `alsa-ucm-conf` never creates the `Speaker` device. **On 7.2+:** the kernel emits the tag, and `alsa-ucm-conf ≤ 1.2.16.1` ships nothing for `tas2783` (while upstream PR #812's `tas2783.conf` in `1.2.17+` omits stereo channel assignment) | 7.1: "Dummy Output" / `pro-audio` only. 7.2: UCM fails to open (`failed to import hw:1 use case configuration -2`). 7.3+ with stock UCM: mono | Three UCM files in `configs/` + SKU-probed `CardLongName` override + `sof-soundwire_acp-dmic.conf` (`170%` / `+13.8 dB` DMIC boost) |
| 2 | The stock driver initializes **both** amps with DSP cluster index `0x01` (ASUS ACPI tables carry no usable SDCA/DisCo function data, so the driver falls back to a static init sequence) | Mono from **one** speaker (left amp only) | Patched **DKMS module** (`module/`, rebased on the 7.3 driver) adding `tas2783-N Channel Playback` (`Off` / `Left` / `Right`) + UCM setting `tas2783-1=Left`, `tas2783-2=Right` |
| 3 | **On 7.1 / 7.2:** `s2idle` drops slaves off the SoundWire bus or wipes the TAS2783 DSP firmware (`error playback without fw download`). **On 7.3+:** upstream landed Andrey Golovko's 3 `tas2783-sdw` `s2idle` fixes, while `rt721-sdca` runtime-suspends ~7 s after probe and fails to resume (`-61`) | Dead/muted audio after sleep, or whole `HiFi` profile dropped when `rt721` fails to resume | `90-px13-rt721-no-autosuspend.rules` keeps `rt721` `control=on` / `active`; `50-px13-soundwire` + `px13-soundwire-recover.sh` runs `POLICY=always` on `< 7.3` and **`POLICY=auto`** on `>= 7.3` (no-op on healthy wake; full stack reload only if a slave fails to re-attach) |

---

## Kernel 7.1 / 7.2 / 7.3+ Compatibility

- **Single DKMS source across 7.1, 7.2, and 7.3+:** `module/Makefile` probes `sdca_parse_function()` and `sdw_slave_wait_for_init()` directly from the target kernel's headers at build time (`-DPX13_SDCA_PARSE_HAS_DESC`, `-DPX13_SDCA_PARSE_HAS_SDW`, `-DHAVE_SDW_SLAVE_WAIT_FOR_INIT`), rather than relying on `LINUX_VERSION_CODE`.
- **Verified on Fedora 44 across `7.2.15-200.fc44.x86_64` → `7.3.3-200.fc44.x86_64`:** `dkms` + `kernel-devel-matched` automatically rebuilds and MOK-signs `/lib/modules/$(uname -r)/extra/snd-soc-tas2783-sdw.ko.xz` during `dnf` kernel upgrades, and `px13-soundwire-recover.sh` automatically transitions from `POLICY=always` to `POLICY=auto` on `>= 7.3`.
- **Watch item for future `alsa-ucm` package updates:** When your distro updates `alsa-ucm` (`alsa-ucm-conf`), the package manager may overwrite `/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf` with upstream's file (which lacks the `tas2783-{1,2} Channel Playback` `Left`/`Right` `cset`s, reverting speakers to mono). Run `bash check-audio.sh` after updates; if it flags mono channels, re-run `bash install-durable.sh`.
- **Cross-kernel build gate:** Run `bash .gate` to compile-test `module/` against every installed `/usr/lib/modules/*/build` tree and run syntax + `shellcheck` across all scripts.

---

## What Gets Installed Where

| File (repo) | Installed to | Purpose |
|---|---|---|
| `module/` | `/usr/src/snd-soc-tas2783-sdw-px13-1.2` (DKMS) | Stock 7.3 `tas2783-sdw` driver (with `s2idle` resume fixes) + `Channel Playback` (`Off`/`Left`/`Right`) control |
| `configs/ucm-card-override.conf.in` | `/usr/share/alsa/ucm2/conf.d/<CardDriver>/<CardLongName>.conf` | Probed per-SKU UCM override (`HN7306EAC`, `HN7306EA`, etc.); unowned by any package so it survives `alsa-ucm` updates |
| `configs/sof-soundwire_tas2783.conf` | `/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf` | `Speaker` device for UCM `HiFi` profile; sets `tas2783-1 = Left` (`1`) and `tas2783-2 = Right` (`2`) |
| `configs/codecs_tas2783_init.conf` | `/usr/share/alsa/ucm2/codecs/tas2783/init.conf` | Hardware volume control remap |
| `configs/sof-soundwire_acp-dmic.conf` | `/usr/share/alsa/ucm2/sof-soundwire/acp-dmic.conf` | Internal DMIC configuration (`install-durable.sh` boosts `Mic` source to `170%` / `+13.8 dB`) |
| `90-px13-rt721-no-autosuspend.rules` | `/etc/udev/rules.d/` | Keeps `rt721` jack codec `power/control=on` so it never enters broken runtime suspend (`-ENODATA`) |
| `50-px13-soundwire` | `/usr/lib/systemd/system-sleep/` | Non-blocking `systemd-sleep` post hook (`systemd-run --no-block --collect`) |
| `px13-soundwire-recover.sh` | `/usr/local/lib/` | `s2idle` recovery worker (`POLICY=auto` on `>= 7.3`, `POLICY=always` on `< 7.3`; logs to `/var/log/px13-soundwire-resume.log`) |
| `lib/px13-detect.sh` | `/usr/local/lib/px13-audio-detect.sh` | Shared runtime hardware/card/session detection library |
| — | `/etc/px13-audio-fix.conf` | Cached `PX13_ACP_PCI` and `PX13_CARD_LONGNAME` (and optional `PX13_RECOVER_POLICY` override) |

---

## Credits

- **[ftoleedo/px13-audio-fix](https://github.com/ftoleedo/px13-audio-fix)** — DKMS module packaging, SKU-independent UCM overrides, `rt721` runtime-PM udev rule, `s2idle` recovery architecture, and `check-audio.sh` / `.gate`.
- **nealstar** — original 16-patch series, including the `Channel Playback` SDCA `CLUSTERINDEX` control.
- **Andrey Golovko** — upstream Kernel 7.3 `tas2783-sdw` `s2idle` resume fixes.
- **TI / Niranjan H Y, Baojun Xu, Kevin Lu** — upstream `tas2783-sdw` driver.
- **jamescutts, dmicheel, DevGrishin, leepaulmann** — SKU `CardLongName` discovery and cross-kernel API testing in [CachyOS/linux-cachyos#737](https://github.com/CachyOS/linux-cachyos/issues/737).

## License

Guide and helper scripts: [CC0 1.0 Universal](LICENSE). Kernel module (`module/`) and patches (`patches/`): GPL-2.0 (derived from the upstream Linux kernel driver).
