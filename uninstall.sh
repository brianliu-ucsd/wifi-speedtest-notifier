#!/bin/bash
set -euo pipefail

LABEL="com.wifispeedtest.notifier"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
rm -f "$PLIST_DEST"

echo "Uninstalled. The LaunchAgent is stopped and removed."
echo "Logs and state files were left in place:"
echo "  $HOME/Library/Logs/wifi-speedtest.log"
echo "  $HOME/Library/Logs/wifi-speedtest.launchd.log"
echo "  $HOME/Library/Application Support/wifi-speedtest/"
echo "Delete them manually, or remove this project directory, if you want a clean slate."
