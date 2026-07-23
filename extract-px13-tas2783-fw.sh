#!/usr/bin/env bash
set -euo pipefail

# ASUS ProArt PX13 HN7306 TAS2783 firmware extraction / install,
# plus WirePlumber configuration for the internal speakers.
#
# Run as your normal user (NOT with sudo) — it uses sudo only where needed
# and writes WirePlumber config into your own home directory.
#
# Firmware blobs: if the calibration blobs are already sitting in the SAME
# directory as this script, they are reused and the download + wine
# extraction is skipped entirely. Accepted local names, per slave address
# (8 and B):
#     1714-1-0x8.bin / 1714-1-0xB.bin  (as shipped in the ASUS driver)
#   or
#     1714-1-8.bin  / 1714-1-B.bin     (the de-prefixed names)
# Otherwise the official ASUS TI SmartAmp DCH driver is downloaded and the
# blobs are extracted from it.
#
# Both the 0x-prefixed and de-prefixed names are installed, so the load is
# clean on every kernel: 7.1+ requests 1714-1-0x8.bin first, while 7.0
# (and the 7.1+ fallback) requests 1714-1-8.bin. See README "Why this is
# needed".

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: run this as your normal user, not as root/sudo." >&2
  echo "       (WirePlumber config must land in YOUR home directory;" >&2
  echo "        the script calls sudo itself where needed.)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=/tmp/px13-tas2783

CARD="alsa_card.pci-0000_c4_00.5-platform-amd_sdw"
SINK="alsa_output.pci-0000_c4_00.5-platform-amd_sdw.pro-output-2"

# Resolve one blob (by slave address) inside a directory. Prefers the
# 0x-prefixed name, falls back to the de-prefixed one. Echoes the path.
find_blob() {
  local addr=$1 dir=$2 n
  for n in "1714-1-0x${addr}.bin" "1714-1-${addr}.bin"; do
    if [ -f "$dir/$n" ]; then printf '%s\n' "$dir/$n"; return 0; fi
  done
  return 1
}

# 1. Reuse blobs sitting next to the script, if present.
SRC_8="$(find_blob 8 "$SCRIPT_DIR" || true)"
SRC_B="$(find_blob B "$SCRIPT_DIR" || true)"

if [ -n "$SRC_8" ] && [ -n "$SRC_B" ]; then
  echo "==> Found firmware next to the script; skipping download/extraction:"
  echo "      $SRC_8"
  echo "      $SRC_B"
else
  echo "==> Firmware not found next to the script; extracting from ASUS driver..."
  URL="https://dlcdnets.asus.com/pub/ASUS/nb/Image/Driver/Audio/47519/SmartAMP_TI_DCH_TexasInstruments_Z_V6.3.1.15_47519.exe?model=HN7306EAC"

  mkdir -p "$WORK"
  cd "$WORK"

  echo "==> Downloading ASUS TI SmartAmp driver (4.3 MB)..."
  curl -fL -A "Mozilla/5.0" -o smartamp.exe "$URL"

  echo "==> Initialising wine prefix..."
  export WINEPREFIX="$WORK/wineprefix" WINEDEBUG=-all
  wineboot -i >/dev/null 2>&1 || true

  echo "==> Running installer; snapshotting temp files..."
  rm -rf "$WORK/snapshot"
  mkdir -p "$WORK/snapshot"
  TEMP="$WINEPREFIX/drive_c/users/$USER/AppData/Local/Temp"

  # Watch temp dir while installer runs and grab files before they get cleaned up.
  (
    while true; do
      for d in "$TEMP"/is-*; do
        [ -d "$d" ] && rsync -a "$d/" "$WORK/snapshot/" 2>/dev/null
      done
      sleep 0.2
    done
  ) &
  WATCHER=$!
  trap 'kill $WATCHER 2>/dev/null || true' EXIT

  wine "$WORK/smartamp.exe" /SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=Z:\\tmp\\px13-tas2783\\install.log 2>/dev/null
  sleep 5
  kill $WATCHER 2>/dev/null || true

  # Locate the extracted blobs.
  SRC=$(find "$WORK/snapshot" -name "1714-1-0x8.bin" | head -1)
  [ -n "$SRC" ] || { echo "ERROR: Did not find 1714-1-0x8.bin. Snapshot:"; find "$WORK/snapshot" | head; exit 1; }
  SRC_DIR=$(dirname "$SRC")
  echo "==> Found firmware in $SRC_DIR"
  SRC_8="$(find_blob 8 "$SRC_DIR")"
  SRC_B="$(find_blob B "$SRC_DIR")"
fi

# Sanity: both blobs must be resolved before we touch the system.
[ -n "$SRC_8" ] && [ -n "$SRC_B" ] || { echo "ERROR: could not resolve both firmware blobs (addr 8 and B)."; exit 1; }

# 2. Install each blob under BOTH names (0x-prefixed + de-prefixed), in the
#    firmware root and the ti/audio/tas2783 subdir.
install_blob() {
  local src=$1 addr=$2 d
  for d in /lib/firmware /lib/firmware/ti/audio/tas2783; do
    sudo install -m 644 "$src" "$d/1714-1-0x${addr}.bin"
    sudo install -m 644 "$src" "$d/1714-1-${addr}.bin"
  done
}

echo "==> Installing to /lib/firmware/ (will prompt for sudo)..."
sudo install -d -m 755 /lib/firmware/ti/audio/tas2783
install_blob "$SRC_8" 8
install_blob "$SRC_B" B

# 3. SELinux relabel (Fedora & friends). Files installed from /tmp or $HOME
#    inherit the wrong context, which can block the kernel firmware loader
#    on an enforcing system. No-op where restorecon doesn't exist (Arch).
if command -v restorecon >/dev/null 2>&1; then
  echo "==> SELinux detected; restoring firmware file contexts..."
  sudo restorecon -Rv /lib/firmware/1714-1-*.bin /lib/firmware/ti/audio/tas2783 || true
fi

# 4. WirePlumber config: force the pro-audio profile (UCM exposes no
#    "Speakers" port for this card), keep the speaker sink from suspending
#    (prevents most SoundWire desyncs), and give it a high session priority
#    so it becomes the default sink.
WP_DIR="$HOME/.config/wireplumber/wireplumber.conf.d"
WP_CONF="$WP_DIR/51-strix-halo-audio.conf"
echo "==> Writing $WP_CONF ..."
mkdir -p "$WP_DIR"
cat > "$WP_CONF" <<EOF
monitor.alsa.rules = [
  {
    matches = [
      { device.name = "$CARD" }
    ]
    actions = {
      update-props = {
        device.profile = "pro-audio"
      }
    }
  }
  {
    matches = [
      { node.name = "$SINK" }
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
EOF

echo "==> Restarting WirePlumber/PipeWire..."
if systemctl --user is-active --quiet wireplumber 2>/dev/null; then
  systemctl --user restart wireplumber pipewire pipewire-pulse
  # The speaker sink only exists once the kernel has loaded the firmware
  # (i.e. after the post-install reboot). Tolerate failure on first run.
  if pactl set-default-sink "$SINK" 2>/dev/null; then
    echo "==> Default sink set to internal speakers."
  else
    echo "==> Speaker sink not present yet (expected before the reboot)."
    echo "    The WirePlumber config persists; after rebooting the sink should"
    echo "    appear and win by priority. If not, run:"
    echo "      pactl set-default-sink $SINK"
  fi
else
  echo "==> WirePlumber user service not running; config written, it will be"
  echo "    picked up when WirePlumber starts."
fi

echo
echo "==> Done. Firmware installed and WirePlumber configured."
echo "    Reboot, then check: dmesg | grep tas2783"
echo "    You should NOT see 'Direct firmware load for 1714-1-* failed'."
echo "    Test playback:"
echo "      pw-cat --target=$SINK --playback /usr/share/sounds/alsa/Front_Center.wav"
