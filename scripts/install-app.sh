#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product FanMenu --product fand
# The MCP server runs from mcp/dist — a stale dist silently ships an old tool
# set (0.2 tools while src says 0.3). Build it as part of shipping the app.
if command -v npm >/dev/null 2>&1; then
  [ -d mcp/node_modules ] || npm --prefix mcp install --no-audit --no-fund
  npm --prefix mcp run build
else
  echo "WARN: npm not found — mcp/dist left as-is and may be stale" >&2
fi
APP="Fan Control.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FanMenu "$APP/Contents/MacOS/Fan Control"
cp .build/release/fand "$APP/Contents/MacOS/fand"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp launchd/com.fancontrol.fand.plist "$APP/Contents/Resources/com.fancontrol.fand.plist"
cp Resources/install-fand.sh "$APP/Contents/Resources/install-fand.sh"
chmod +x "$APP/Contents/MacOS/Fan Control" "$APP/Contents/MacOS/fand" "$APP/Contents/Resources/install-fand.sh"
codesign --force --deep --sign - "$APP" 2>/dev/null || true
DEST="/Applications/Fan Control.app"
# Replace any running copy, then install.
pkill -x "Fan Control" 2>/dev/null || true
pkill -x FanMenu 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "installed $DEST"
open "$DEST"
