#!/usr/bin/env bash
# Bootstrap the SDK onto the mounted HDD array (idempotent), create the AVD, and
# boot the emulator headless. First run downloads ~2-3 GB into /data/storage; later
# runs skip straight to boot.
set -euo pipefail

SDK="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
API="${ANDROID_API:-34}"
TAG="${ANDROID_TAG:-google_apis}"
ABI="${ANDROID_ABI:-x86_64}"
IMG="system-images;android-${API};${TAG};${ABI}"
AVD="${AVD_NAME:-sfit_test}"
DEVICE="${AVD_DEVICE:-pixel_6}"

mkdir -p "$SDK" "$ANDROID_AVD_HOME"

# 1) cmdline-tools (one-time) — installed into the mounted SDK root.
if [ ! -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
  echo ">> Installing Android cmdline-tools into $SDK ..."
  curl -fsSL -o /tmp/cmdtools.zip \
    https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
  rm -rf "$SDK/cmdline-tools" && mkdir -p "$SDK/cmdline-tools"
  unzip -q /tmp/cmdtools.zip -d "$SDK/cmdline-tools"
  mv "$SDK/cmdline-tools/cmdline-tools" "$SDK/cmdline-tools/latest"
  rm -f /tmp/cmdtools.zip
fi

# 2) platform-tools + emulator + system image (idempotent; resumes if partial).
yes | sdkmanager --licenses >/dev/null 2>&1 || true
echo ">> Ensuring platform-tools, emulator, and $IMG ..."
sdkmanager --install "platform-tools" "emulator" "$IMG" >/dev/null

# 3) AVD on the array (created once).
if ! avdmanager list avd 2>/dev/null | grep -q "Name: $AVD"; then
  echo ">> Creating AVD '$AVD' ($DEVICE, $IMG) ..."
  echo "no" | avdmanager create avd -n "$AVD" -k "$IMG" -d "$DEVICE" --force
fi

# 4) Sanity: warn loudly if KVM is missing (emulator will be unusably slow).
if [ ! -e /dev/kvm ]; then
  echo "!! /dev/kvm not present in container — enable VT-x in BIOS and map the device."
  echo "!! Booting in software mode (very slow); set ACCEL=off to silence -accel auto errors."
fi

echo ">> Booting emulator '$AVD' (headless) ..."
exec emulator -avd "$AVD" \
  -no-window -no-audio -no-boot-anim -no-snapshot \
  -gpu swiftshader_indirect \
  -accel "${ACCEL:-auto}" \
  -memory "${EMU_MEMORY:-2048}" \
  -wipe-data \
  "$@"
