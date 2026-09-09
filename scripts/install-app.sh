#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product FanMenu
APP="Fan Control.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FanMenu "$APP/Contents/MacOS/Fan Control"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/Fan Control"
codesign --force --deep --sign - "$APP" 2>/dev/null || true
DEST="/Applications/Fan Control.app"
# Replace any running copy, then install.
pkill -x "Fan Control" 2>/dev/null || true
pkill -x FanMenu 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "installed $DEST"
open "$DEST"
