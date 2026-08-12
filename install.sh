#!/bin/bash
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required but not installed."
  echo "Install it from https://brew.sh, then re-run this script."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.wifispeedtest.notifier"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs"

if ! command -v jq >/dev/null 2>&1; then
  echo "Installing jq..."
  brew install jq
fi

if ! command -v speedtest >/dev/null 2>&1; then
  echo "Installing Ookla Speedtest CLI..."
  brew tap teamookla/speedtest
  brew trust --formula teamookla/speedtest/speedtest
  brew install speedtest
fi

chmod +x "$SCRIPT_DIR/wifi-speedtest.sh"
mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

if command -v shortcuts >/dev/null 2>&1 && ! shortcuts list 2>/dev/null | grep -qxF "Get Wi-Fi SSID"; then
  echo ""
  echo "Optional: notifications currently show the gateway IP (e.g. \"Speedtest:"
  echo "192.168.1.1\") instead of your network's name. To get the name instead, build a"
  echo "Shortcut named \"Get Wi-Fi SSID\". See steps in README. wifi-speedtest.sh picks it"
  echo "up automatically once it exists - no need to re-run this installer."
  echo ""
fi

sed \
  -e "s|__SCRIPT_PATH__|$SCRIPT_DIR/wifi-speedtest.sh|" \
  -e "s|__LOG_PATH__|$LOG_DIR|" \
  "$SCRIPT_DIR/com.wifispeedtest.notifier.plist.template" >"$PLIST_DEST"

launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"

echo "Sending a test notification..."
osascript \
  -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
  -e 'end run' \
  -- "If you can see this, notifications are working." "wifi-speedtest-notifier installed" >/dev/null 2>&1

echo ""
echo "Installed and running. It will also run once now (RunAtLoad) and test the"
echo "network you're currently on."
echo ""
echo "If you didn't see the test notification, check System Settings > Notifications"
echo "and allow notifications for Script Editor / osascript."
