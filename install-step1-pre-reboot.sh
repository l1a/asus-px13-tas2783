#!/usr/bin/env bash
# ASUS ProArt PX13 (HN7306*) — Step 1 (Pre-Reboot Setup) for Fedora (Secure Boot + SELinux)
#
# Installs Fedora prerequisites, queues the DKMS MOK key for Secure Boot enrollment,
# builds/signs the patched tas2783-sdw DKMS module, installs UCM + rt721 udev
# rules + s2idle recovery hook, fixes SELinux labels, and preserves docked/BT
# sink priority.
#
# Run from your normal user terminal (NOT under sudo):
#   bash ./install-step1-pre-reboot.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/install-durable.sh" ]; then
  REPO_DIR="$SCRIPT_DIR"
elif [ -f "$SCRIPT_DIR/repo/install-durable.sh" ]; then
  REPO_DIR="$SCRIPT_DIR/repo"
else
  echo "ERROR: Could not find install-durable.sh in $SCRIPT_DIR or $SCRIPT_DIR/repo" >&2
  exit 1
fi
BACKUP_DIR="$SCRIPT_DIR/backup-pre-install"
KREL="$(uname -r)"

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: Run this script as your normal desktop user, NOT with sudo." >&2
  echo "       It will prompt for sudo when needed and keep your PipeWire session intact." >&2
  exit 1
fi

# Save a pre-install snapshot of WirePlumber state if not already backed up,
# and preserve current default-nodes across install-durable.sh.
mkdir -p "$BACKUP_DIR/wireplumber"
if [ ! -f "$BACKUP_DIR/wireplumber/default-nodes" ] && [ -d "$HOME/.local/state/wireplumber" ]; then
  cp -a "$HOME/.local/state/wireplumber/." "$BACKUP_DIR/wireplumber/"
fi
SAVED_DEFAULT_NODES=""
if [ -f "$HOME/.local/state/wireplumber/default-nodes" ]; then
  SAVED_DEFAULT_NODES="$(mktemp)"
  trap 'rm -f "$SAVED_DEFAULT_NODES"' EXIT
  cp -a "$HOME/.local/state/wireplumber/default-nodes" "$SAVED_DEFAULT_NODES"
fi
PRE_DEFAULT_SINK="$(pactl get-default-sink 2>/dev/null || true)"

echo "==> Authenticating sudo..."
sudo -v

echo
echo "==> [1/5] Installing Fedora prerequisites (dkms, kernel-devel-$KREL, alsa-ucm-utils)..."
sudo dnf install -y dkms "kernel-devel-$KREL" kernel-devel-matched alsa-ucm-utils

echo
echo "==> [2/5] Preparing DKMS Secure Boot MOK signing key..."
if [ ! -f /var/lib/dkms/mok.pub ]; then
  sudo dkms generate_mok
fi
sudo ls -l /var/lib/dkms/mok.key /var/lib/dkms/mok.pub

if sudo mokutil --test-key /var/lib/dkms/mok.pub 2>/dev/null | grep -qi 'already enrolled'; then
  echo "    DKMS MOK key is already enrolled in UEFI MokList — no MokManager step needed!"
  MOK_NEEDS_ENROLL=0
else
  echo
  echo "    +-------------------------------------------------------------------------+"
  echo "    | SECURE BOOT MOK KEY ENROLLMENT                                          |"
  echo "    | Choose a temporary one-time password below (e.g. 8-12 simple ASCII      |"
  echo "    | characters — UEFI MokManager uses a US QWERTY layout).                  |"
  echo "    | You will type this password ONCE on the blue MokManager screen during   |"
  echo "    | your next reboot so UEFI trusts DKMS-signed kernel modules.             |"
  echo "    +-------------------------------------------------------------------------+"
  sudo mokutil --import /var/lib/dkms/mok.pub
  MOK_NEEDS_ENROLL=1
fi

echo
echo "==> [3/5] Running install-durable.sh (DKMS + UCM + rt721 udev)..."
# Note: While Secure Boot has not yet enrolled mok.pub (prior to reboot), the
# in-memory stock module stays loaded (refcount > 0) and NEED_REBOOT=1 is expected.
bash "$REPO_DIR/install-durable.sh"

# Preserve docked/Bluetooth sink preference if an external sink was active beforehand
if [ -n "$SAVED_DEFAULT_NODES" ] && [ -f "$SAVED_DEFAULT_NODES" ]; then
  case "$PRE_DEFAULT_SINK" in
    ""|auto_null|*amd_sdw*) ;;
    *)
      cp -a "$SAVED_DEFAULT_NODES" "$HOME/.local/state/wireplumber/default-nodes"
      systemctl --user restart wireplumber
      sleep 2
      echo "    Restored external default-sink priority ($PRE_DEFAULT_SINK) so docked/BT audio stays preferred."
      ;;
  esac
fi

echo
echo "==> [4/5] Installing s2idle suspend/resume recovery hook (--no-test before MOK reboot)..."
bash "$REPO_DIR/install-resume-recovery.sh" --no-test

echo
echo "==> [5/5] Enforcing SELinux contexts and verifying signed DKMS module on disk..."
if command -v restorecon >/dev/null 2>&1; then
  sudo restorecon -FRv \
    /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf \
    /usr/share/alsa/ucm2/codecs/tas2783 \
    /usr/share/alsa/ucm2/conf.d/amd-soundwire \
    /etc/udev/rules.d/90-px13-rt721-no-autosuspend.rules \
    /etc/px13-audio-fix.conf \
    /usr/lib/systemd/system-sleep/50-px13-soundwire \
    /usr/local/lib/px13-soundwire-recover.sh \
    /usr/local/lib/px13-audio-detect.sh
fi

echo
echo "    --- DKMS & Module Signature Check ---"
dkms status snd-soc-tas2783-sdw-px13
MOD_FILE="$(modinfo -k "$KREL" snd_soc_tas2783_sdw -F filename)"
MOD_SIGNER="$(modinfo -k "$KREL" snd_soc_tas2783_sdw -F signer || true)"
printf '    module path   : %s\n' "$MOD_FILE"
printf '    module signer : %s\n' "${MOD_SIGNER:-(UNSIGNED - DO NOT REBOOT WITHOUT CHECKING)}"

case "$MOD_FILE" in
  */extra/*|*/updates/*) ;;
  *)
    echo "ERROR: Expected module under /extra/ or /updates/, got: $MOD_FILE" >&2
    exit 1
    ;;
esac

if [ -z "$MOD_SIGNER" ]; then
  echo "ERROR: DKMS module has no cryptographic signature! Secure Boot will reject it." >&2
  exit 1
fi

echo
echo "=========================================================================="
echo "PRE-REBOOT SETUP COMPLETE"
echo "=========================================================================="
if [ "$MOK_NEEDS_ENROLL" -eq 1 ]; then
  echo "Next steps:"
  echo "  1. Reboot when ready:  sudo reboot"
  echo "  2. On the blue 'Perform MOK management' screen (press a key before timeout):"
  echo "       Enroll MOK -> Continue -> Yes -> <enter one-time password> -> Reboot"
  echo "  3. Unlock LUKS (keep your recovery passphrase handy just in case; PCR 7 should"
  echo "     remain unchanged since MOK uses PCR 14)."
  echo "  4. After login, verify stereo speakers + internal mic:"
  echo "       bash \"$SCRIPT_DIR/verify-step2-post-reboot.sh\""
else
  echo "Next steps:"
  echo "  1. Reboot when ready:  sudo reboot"
  echo "  2. After login, verify stereo speakers + internal mic:"
  echo "       bash \"$SCRIPT_DIR/verify-step2-post-reboot.sh\""
fi
echo
echo "If anything goes wrong (even from a Ctrl+Alt+F3 TTY), revert everything with:"
echo "  bash \"$SCRIPT_DIR/revert-px13-audio.sh\" --yes"
