#!/bin/bash
# Uninstall: revert fans to auto, unload daemon.
curl -s -X POST localhost:8765/auto >/dev/null 2>&1 || true
sudo launchctl bootout system/com.fancontrol.fand 2>/dev/null || sudo launchctl unload /Library/LaunchDaemons/com.fancontrol.fand.plist 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/com.fancontrol.fand.plist /usr/local/bin/fand /usr/local/bin/fanctl
echo "uninstalled (fans back to auto)"
