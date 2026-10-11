#!/bin/bash
# Builds build/notwindows.app. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# SwiftPM's Swift Build engine records the deployment target as the SDK version, and macOS then runs the app in
# compatibility mode with the old window design and its redraw glitches. Record the real SDK instead.
MIN_MACOS=14.0 # keep in step with Package.swift
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
LINK_FLAGS=(-Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_MACOS" -Xlinker "$SDK_VERSION")

swift build -c "$CONFIG" "${LINK_FLAGS[@]}"
BIN="$(swift build -c "$CONFIG" "${LINK_FLAGS[@]}" --show-bin-path)/notwindows"

if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift Resources/AppIcon.icns
fi

APP=build/notwindows.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/notwindows"
cp "$(dirname "$BIN")/notwindows-link-helper" "$APP/Contents/MacOS/notwindows-link-helper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/rosettax87 "$APP/Contents/Resources/rosettax87"
mkdir -p "$APP/Contents/Resources/winerosetta"
cp Resources/winerosetta/winerosetta.dll "$APP/Contents/Resources/winerosetta/"
codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"
