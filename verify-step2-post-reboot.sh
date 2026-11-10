#!/usr/bin/env bash
# ASUS ProArt PX13 (HN7306*) — Step 2 (Post-Reboot Verification)
#
# Run after rebooting and enrolling the DKMS MOK key:
#   bash ./verify-step2-post-reboot.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/check-audio.sh" ]; then
  REPO_DIR="$SCRIPT_DIR"
elif [ -f "$SCRIPT_DIR/repo/check-audio.sh" ]; then
  REPO_DIR="$SCRIPT_DIR/repo"
else
  echo "ERROR: Could not find check-audio.sh in $SCRIPT_DIR or $SCRIPT_DIR/repo" >&2
  exit 1
fi

echo "==> [1/4] Checking Secure Boot & DKMS MOK enrollment..."
mokutil --sb-state || true
if [ -f /var/lib/dkms/mok.pub ]; then
  mokutil --test-key /var/lib/dkms/mok.pub || true
fi

echo
echo "==> [2/4] Running invariant check (check-audio.sh)..."
bash "$REPO_DIR/check-audio.sh"
CHECK_RC=$?

echo
echo "==> [3/4] Checking PipeWire internal Speaker sink & internal DMIC source..."
SPK_SINK="$(pactl list short sinks 2>/dev/null | awk '/sdw/ && /[Ss]peaker/ { print $2; exit }')"
MIC_SRC="$(pactl list short sources 2>/dev/null | awk '/sdw/ && /Mic__source/ { print $2; exit }')"
printf '    Speaker sink : %s\n' "${SPK_SINK:-(MISSING)}"
if [ -n "${SPK_SINK:-}" ]; then
  printf '    Speaker vol  : %s\n' "$(pactl get-sink-volume "$SPK_SINK" | head -n 1)"
fi
printf '    DMIC source  : %s\n' "${MIC_SRC:-(MISSING)}"
if [ -n "${MIC_SRC:-}" ]; then
  printf '    DMIC vol     : %s\n' "$(pactl get-source-volume "$MIC_SRC" | head -n 1)"
fi

echo
echo "==> [4/4] Playing stereo channel test directly on the internal laptop speakers..."
if [ -n "${SPK_SINK:-}" ] && [ -f /usr/share/sounds/alsa/Front_Left.wav ]; then
  echo "    Playing Front_Left.wav on $SPK_SINK ..."
  pw-play --target="$SPK_SINK" /usr/share/sounds/alsa/Front_Left.wav
  sleep 0.4
  echo "    Playing Front_Right.wav on $SPK_SINK ..."
  pw-play --target="$SPK_SINK" /usr/share/sounds/alsa/Front_Right.wav
else
  echo "    SKIPPED direct pw-play test (Speaker sink or Front_Left.wav missing)."
fi

echo
if [ "$CHECK_RC" -eq 0 ] && [ -n "${SPK_SINK:-}" ] && [ -n "${MIC_SRC:-}" ]; then
  echo "SUCCESS: Internal stereo speakers + internal DMIC + s2idle hook are all active."
else
  echo "WARNING: One or more checks reported an issue above (check_rc=$CHECK_RC)."
  echo "To revert completely at any time: bash \"$SCRIPT_DIR/revert-px13-audio.sh\" --yes"
  exit 1
fi
