#!/bin/bash
# Install fand as a root LaunchDaemon + link fanctl. No paid cert needed (plain sudo install).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product fand --product fanctl
sudo cp .build/release/fand /usr/local/bin/fand
sudo cp .build/release/fanctl /usr/local/bin/fanctl
sudo cp launchd/com.fancontrol.fand.plist /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/com.fancontrol.fand.plist 2>/dev/null || sudo launchctl load /Library/LaunchDaemons/com.fancontrol.fand.plist
echo "fand installed. Check: curl -s localhost:8765/status | head -c 400"
