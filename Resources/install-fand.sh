#!/bin/bash
# Run as root (via the app's admin prompt). Installs fand as a LaunchDaemon
# so it is already running whenever Fan Control opens — including after reboot.
set -euo pipefail
BUNDLE="${1:?app bundle path}"
FAND_SRC="$BUNDLE/Contents/MacOS/fand"
PLIST_SRC="$BUNDLE/Contents/Resources/com.fancontrol.fand.plist"
test -x "$FAND_SRC"
test -f "$PLIST_SRC"
mkdir -p /usr/local/bin
install -m 755 "$FAND_SRC" /usr/local/bin/fand
install -m 644 "$PLIST_SRC" /Library/LaunchDaemons/com.fancontrol.fand.plist
chown root:wheel /usr/local/bin/fand /Library/LaunchDaemons/com.fancontrol.fand.plist
# Replace a hand-started copy so launchd can bind :8765.
pkill -x fand 2>/dev/null || true
launchctl bootout system/com.fancontrol.fand 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.fancontrol.fand.plist
