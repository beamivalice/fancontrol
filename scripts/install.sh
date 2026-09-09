#!/bin/bash
# Installs fand as a root LaunchDaemon so it starts at every boot (asks once).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
echo "Installing LaunchDaemon (needs your password once)…"
# Stop a hand-started copy so launchd can bind :8765.
sudo pkill -x fand 2>/dev/null || true
sudo cp .build/release/fand /usr/local/bin/fand
sudo cp .build/release/fanctl /usr/local/bin/fanctl
sudo cp launchd/com.fancontrol.fand.plist /Library/LaunchDaemons/com.fancontrol.fand.plist
sudo chown root:wheel /Library/LaunchDaemons/com.fancontrol.fand.plist /usr/local/bin/fand /usr/local/bin/fanctl
sudo chmod 644 /Library/LaunchDaemons/com.fancontrol.fand.plist
sudo chmod 755 /usr/local/bin/fand /usr/local/bin/fanctl
sudo launchctl bootout system/com.fancontrol.fand 2>/dev/null || true
sudo launchctl bootstrap system /Library/LaunchDaemons/com.fancontrol.fand.plist
sleep 1
echo "fand will start at every boot as root."
echo "Check: curl -s localhost:8765/status | head -c 200; echo"
