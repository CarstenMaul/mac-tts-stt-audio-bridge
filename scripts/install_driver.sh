#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <path-to-VirtualAudioBridge.driver>"
  exit 2
fi

DRIVER_BUNDLE="$1"
TARGET_DIR="/Library/Audio/Plug-Ins/HAL/VirtualAudioBridge.driver"
DRIVER_BIN="$DRIVER_BUNDLE/Contents/MacOS/VirtualAudioBridge"

if [[ ! -d "$DRIVER_BUNDLE" ]]; then
  echo "Driver bundle not found: $DRIVER_BUNDLE"
  exit 1
fi

if [[ ! -f "$DRIVER_BIN" ]]; then
  echo "Driver executable not found: $DRIVER_BIN"
  exit 1
fi

if [[ "${ALLOW_UNSIGNED_DRIVER:-0}" != "1" ]]; then
  SIGN_INFO="$(codesign -dv --verbose=4 "$DRIVER_BIN" 2>&1 || true)"
  if echo "$SIGN_INFO" | grep -q "Signature=adhoc"; then
    cat <<'EOF'
Refusing to install an ad-hoc signed HAL driver.
macOS will typically reject it and the device will not appear.

Sign the driver with an Apple code-signing identity first, then reinstall.
If you still want to force install for local experiments, run:
  ALLOW_UNSIGNED_DRIVER=1 ./scripts/install_driver.sh <path-to-VirtualAudioBridge.driver>
EOF
    exit 1
  fi
fi

echo "Installing $DRIVER_BUNDLE -> $TARGET_DIR"
sudo rm -rf "$TARGET_DIR"
sudo cp -R "$DRIVER_BUNDLE" "$TARGET_DIR"
sudo chown -R root:wheel "$TARGET_DIR"
sudo killall coreaudiod || true
echo "Installed. Open Audio MIDI Setup and look for 'Virtual Audio Bridge'."
