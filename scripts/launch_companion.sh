#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cmake --build "$ROOT_DIR/build" --target bridge_companion_build

BIN="$ROOT_DIR/swift/.build/release/bridge_companion"
APP_DIR="$ROOT_DIR/build/BridgeCompanion.app"
APP_CONTENTS="$APP_DIR/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"

if [[ ! -x "$BIN" ]]; then
  echo "Missing companion binary: $BIN"
  exit 1
fi

mkdir -p "$APP_MACOS"
cp "$BIN" "$APP_MACOS/BridgeCompanion"

cat > "$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>BridgeCompanion</string>
  <key>CFBundleIdentifier</key>
  <string>com.zaphbot.bridge-companion</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Bridge Companion</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Bridge Companion needs speech recognition to provide Apple STT in test sessions.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Bridge Companion may access microphone-related APIs for audio bridge testing.</string>
</dict>
</plist>
PLIST

open "$APP_DIR"
