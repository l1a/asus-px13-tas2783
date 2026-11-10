#!/usr/bin/env bash
# ASUS ProArt PX13 (HN7306*) — Complete Rollback Script
#
# Reverts 100% of system and user-session changes made by install-step1-pre-reboot.sh
# (both install-durable.sh AND install-resume-recovery.sh, plus WirePlumber state).
# Safe to run from a graphical terminal OR an emergency TTY (Ctrl+Alt+F3).
#
# Usage:
#   bash ./revert-px13-audio.sh
#   bash ./revert-px13-audio.sh --yes
#   bash ./revert-px13-audio.sh --yes --remove-packages
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_WP="$SCRIPT_DIR/backup-pre-install/wireplumber"
DKMS_NAME="snd-soc-tas2783-sdw-px13"
UCM_DIR="/usr/share/alsa/ucm2"

ASSUME_YES=0
REMOVE_PKGS=0

for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    --remove-packages) REMOVE_PKGS=1 ;;
    -h|--help)
      echo "Usage: bash ./revert-px13-audio.sh [--yes] [--remove-packages]"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

if [ "$ASSUME_YES" -eq 0 ]; then
  echo "This will completely remove the PX13 DKMS module, UCM overrides, rt721 udev rule,"
  echo "s2idle resume hook/scripts, and restore pre-install WirePlumber state."
  printf 'Continue? [y/N] '
  read -r ans
  case "$ans" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Cancelled."; exit 0 ;;
  esac
fi

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

TARGET_USER="${PX13_USER:-${SUDO_USER:-$(id -nu)}}"
if [ "$TARGET_USER" = "root" ]; then
  TARGET_USER="$(stat -c '%U' "$SCRIPT_DIR" 2>/dev/null || true)"
fi
TARGET_HOME=""
TARGET_UID=""
TARGET_RT=""
if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ]; then
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null || true)"
  [ -n "$TARGET_UID" ] && TARGET_RT="/run/user/$TARGET_UID"
fi

run_user_bus() {
  if [ -z "$TARGET_RT" ] || [ ! -S "$TARGET_RT/bus" ]; then
    return 0
  fi
  if [ "$(id -u)" -eq "$TARGET_UID" ]; then
    XDG_RUNTIME_DIR="$TARGET_RT" DBUS_SESSION_BUS_ADDRESS="unix:path=$TARGET_RT/bus" "$@"
  else
    runuser -u "$TARGET_USER" -- env \
      XDG_RUNTIME_DIR="$TARGET_RT" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$TARGET_RT/bus" "$@"
  fi
}

run_root true

echo "==> [1/7] Removing DKMS registrations and out-of-tree kernel modules..."
if command -v dkms >/dev/null 2>&1; then
  while read -r ver; do
    [ -n "$ver" ] || continue
    run_root dkms remove "$DKMS_NAME/$ver" --all || true
    echo "    removed DKMS $DKMS_NAME/$ver"
  done < <(dkms status 2>/dev/null | sed -n "s|^$DKMS_NAME/\([^,:/]*\).*|\1|p" | sort -u)
fi

while IFS= read -r -d '' srcdir; do
  run_root rm -rf -- "$srcdir"
  echo "    removed $srcdir"
done < <(/usr/bin/find /usr/src -maxdepth 1 -name "${DKMS_NAME}-*" -print0 2>/dev/null)

while IFS= read -r -d '' ko; do
  run_root rm -f -- "$ko"
  kver="${ko#/usr/lib/modules/}"
  kver="${kver#/lib/modules/}"
  kver="${kver%%/*}"
  run_root depmod -a "$kver" || true
  echo "    removed $ko (updated depmod for $kver)"
done < <(/usr/bin/find /usr/lib/modules -type f \( -path '*/extra/snd-soc-tas2783-sdw.ko*' -o -path '*/updates/snd-soc-tas2783-sdw.ko*' \) -print0 2>/dev/null)
run_root depmod -a "$(uname -r)" || true

echo "==> [2/7] Removing s2idle sleep hook, recovery scripts, and cache..."
for p in \
  /usr/lib/systemd/system-sleep/50-px13-soundwire \
  /usr/local/lib/px13-soundwire-recover.sh \
  /usr/local/lib/px13-audio-detect.sh \
  /etc/px13-audio-fix.conf \
  /var/log/px13-soundwire-resume.log
do
  if [ -e "$p" ] || [ -L "$p" ]; then
    run_root rm -f -- "$p"
    echo "    removed $p"
  fi
done

echo "==> [3/7] Removing rt721 udev rule and reloading udev..."
if [ -e /etc/udev/rules.d/90-px13-rt721-no-autosuspend.rules ]; then
  run_root rm -f -- /etc/udev/rules.d/90-px13-rt721-no-autosuspend.rules
  echo "    removed /etc/udev/rules.d/90-px13-rt721-no-autosuspend.rules"
fi
run_root udevadm control --reload || true

echo "==> [4/7] Removing ALSA UCM overrides and tas2783 blocks..."
for u in \
  "$UCM_DIR/sof-soundwire/tas2783.conf" \
  "$UCM_DIR/codecs/tas2783/init.conf"
do
  if [ -e "$u" ]; then
    run_root rm -f -- "$u"
    echo "    removed $u"
  fi
done
run_root rmdir -- "$UCM_DIR/codecs/tas2783" 2>/dev/null || true

while IFS= read -r -d '' ovr; do
  if grep -qF 'px13-audio-fix' "$ovr" 2>/dev/null; then
    run_root rm -f -- "$ovr"
    echo "    removed $ovr"
  fi
done < <(/usr/bin/find "$UCM_DIR/conf.d" -type f -name '*.conf' -print0 2>/dev/null)

echo "==> [5/7] Checking for any un-enrolled pending MOK import request..."
if command -v mokutil >/dev/null 2>&1; then
  if run_root mokutil --list-new 2>/dev/null | grep -q 'Subject:'; then
    echo "    NOTE: A pending MOK import is queued. If you also want to cancel it before"
    echo "          rebooting, run: sudo mokutil --revoke-import"
  fi
fi

echo "==> [6/7] Restoring pre-install WirePlumber user state and restarting PipeWire..."
if [ -n "$TARGET_HOME" ] && [ -d "$BACKUP_WP" ] && [ -d "$TARGET_HOME/.local/state/wireplumber" ]; then
  run_user_bus systemctl --user stop wireplumber.service pipewire-pulse.service pipewire.service 2>/dev/null || true
  cp -a "$BACKUP_WP/." "$TARGET_HOME/.local/state/wireplumber/"
  chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.local/state/wireplumber" 2>/dev/null || true
  run_user_bus systemctl --user start pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null || true
  echo "    restored $TARGET_HOME/.local/state/wireplumber from backup"
fi

if [ "$REMOVE_PKGS" -eq 1 ] && command -v dnf >/dev/null 2>&1; then
  echo "==> [Optional] Removing newly installed helper RPMs (dkms, alsa-ucm-utils)..."
  run_root dnf remove -y dkms alsa-ucm-utils || true
fi

echo "==> [7/7] Verifying clean post-revert state..."
LEFTOVERS=0
for check_path in \
  /usr/lib/systemd/system-sleep/50-px13-soundwire \
  /usr/local/lib/px13-soundwire-recover.sh \
  /usr/local/lib/px13-audio-detect.sh \
  /etc/px13-audio-fix.conf \
  /etc/udev/rules.d/90-px13-rt721-no-autosuspend.rules \
  "$UCM_DIR/sof-soundwire/tas2783.conf" \
  "$UCM_DIR/codecs/tas2783/init.conf"
do
  if [ -e "$check_path" ]; then
    echo "    WARNING: still present: $check_path" >&2
    LEFTOVERS=$((LEFTOVERS + 1))
  fi
done

ACTIVE_MOD="$(modinfo -k "$(uname -r)" snd_soc_tas2783_sdw -F filename 2>/dev/null || true)"
printf '    resolved module for %s: %s\n' "$(uname -r)" "${ACTIVE_MOD:-(none)}"

if [ "$LEFTOVERS" -eq 0 ]; then
  echo
  echo "REVERT COMPLETE: All PX13 audio-fix files and DKMS modules have been removed."
  echo "Reboot once ('sudo reboot') to ensure the stock in-tree kernel module is loaded cleanly."
else
  echo "WARNING: $LEFTOVERS path(s) could not be removed; inspect output above." >&2
  exit 1
fi
