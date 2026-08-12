#!/bin/bash
set -uo pipefail

# launchd runs jobs with a minimal environment that doesn't include Homebrew's
# install location, regardless of the user's shell PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

STATE_DIR="$HOME/Library/Application Support/wifi-speedtest"
STATE_FILE="$STATE_DIR/state"
LOCK_DIR="$STATE_DIR/run.lock"
LOG_FILE="$HOME/Library/Logs/wifi-speedtest.log"

mkdir -p "$STATE_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOG_FILE"
}

notify() {
  local body="$1" title="$2"
  osascript \
    -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
    -e 'end run' \
    -- "$body" "$title" >/dev/null 2>&1
}

# Best-effort SSID lookup for a friendlier notification/log label. This is
# purely cosmetic: network identity for change-detection stays the gateway
# MAC below, untouched. Requires a manually-built "Get Wi-Fi SSID" Shortcut
# (no CLI/API can create one), so this silently returns nothing on any
# machine that doesn't have it.
# macOS ships no `timeout` binary, hence the manual kill-after-N loop.
get_ssid() {
  command -v shortcuts >/dev/null 2>&1 || return 1
  shortcuts list 2>/dev/null | grep -qxF "Get Wi-Fi SSID" || return 1

  local out_file waited=0
  out_file=$(mktemp)
  shortcuts run "Get Wi-Fi SSID" >"$out_file" 2>/dev/null &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 5 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    rm -f "$out_file"
    return 1
  fi
  wait "$pid" 2>/dev/null
  local status=$? ssid
  ssid=$(cat "$out_file")
  rm -f "$out_file"
  [ "$status" -eq 0 ] && [ -n "$ssid" ] && printf '%s' "$ssid"
}

# Serialize runs: overlapping launchd triggers (WatchPaths + RunAtLoad + StartInterval
# firing close together, e.g. on wake-from-sleep) must not run speedtest concurrently -
# that would silently skew both instances' bandwidth readings and race on state writes.
# mkdir is atomic on POSIX filesystems, so it doubles as a lock; macOS has no `flock`
# binary out of the box, hence this instead of a real file lock.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null
  fi
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "skip: another run already in progress"
    exit 0
  fi
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

WIFI_DEVICE=$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}')
if [ -z "$WIFI_DEVICE" ]; then
  log "error: no Wi-Fi hardware port found"
  exit 1
fi

# Network identity is the default gateway's MAC (from ARP). MAC, not IP,
# since private gateway IPs (192.168.1.1 etc.) collide across unrelated
# networks while a MAC is unique per router.
ROUTE_INFO=$(route -n get default 2>/dev/null)
DEFAULT_IFACE=$(printf '%s' "$ROUTE_INFO" | awk '/interface:/{print $2}')
GATEWAY_IP=$(printf '%s' "$ROUTE_INFO" | awk '/gateway:/{print $2}')

CURRENT_KEY=""
if [ "$DEFAULT_IFACE" = "$WIFI_DEVICE" ] && [ -n "$GATEWAY_IP" ]; then
  GATEWAY_MAC=$(arp -n "$GATEWAY_IP" 2>/dev/null | awk '{print $4}')
  if [ -z "$GATEWAY_MAC" ] || [ "$GATEWAY_MAC" = "(incomplete)" ]; then
    # ARP entry not populated yet (e.g. right after association) - force it.
    ping -c1 -W1 "$GATEWAY_IP" >/dev/null 2>&1
    GATEWAY_MAC=$(arp -n "$GATEWAY_IP" 2>/dev/null | awk '{print $4}')
  fi
  if [ -n "$GATEWAY_MAC" ] && [ "$GATEWAY_MAC" != "(incomplete)" ]; then
    CURRENT_KEY="$GATEWAY_MAC"
  fi
fi

LAST_KEY=""
LAST_OUTCOME=""
if [ -f "$STATE_FILE" ]; then
  LAST_KEY=$(sed -n '1p' "$STATE_FILE")
  LAST_OUTCOME=$(sed -n '3p' "$STATE_FILE")
fi

write_state() {
  printf '%s\n%s\n%s\n' "$1" "$2" "$3" >"$STATE_FILE"
}

if [ -z "$CURRENT_KEY" ]; then
  if [ "$LAST_KEY" != "" ] || [ ! -f "$STATE_FILE" ]; then
    write_state "" "" ""
    log "disconnected from Wi-Fi (on Ethernet, offline, or gateway unreachable)"
  fi
  exit 0
fi

# Act if the network changed, OR it's unchanged but the last test on it failed
# (e.g. a captive portal) - this retries on the next check (a rejoin, or the
# next StartInterval poll, whichever comes first) instead of the state file
# permanently silencing it after one failure.
if [ "$CURRENT_KEY" = "$LAST_KEY" ] && [ "$LAST_OUTCOME" = "ok" ]; then
  exit 0
fi

SSID=$(get_ssid)
NETWORK_LABEL="${SSID:-$GATEWAY_IP}"

# Let the connection settle (DHCP, DNS, captive portal redirect) before testing.
sleep 5

if ! command -v speedtest >/dev/null 2>&1; then
  log "error: speedtest CLI not found on PATH"
  write_state "$CURRENT_KEY" "$GATEWAY_IP" "fail"
  notify "speedtest CLI is not installed - run install.sh again" "Speedtest failed: $NETWORK_LABEL"
  exit 1
fi

RESULT_JSON=$(speedtest --accept-license --accept-gdpr -f json 2>>"$LOG_FILE")
STATUS=$?

if [ $STATUS -ne 0 ] || [ -z "$RESULT_JSON" ]; then
  write_state "$CURRENT_KEY" "$GATEWAY_IP" "fail"
  log "speedtest failed on network $GATEWAY_IP (exit $STATUS)"
  notify "Could not complete a speed test on this network" "Speedtest failed: $NETWORK_LABEL"
  exit 1
fi

DOWNLOAD_MBPS=$(printf '%s' "$RESULT_JSON" | jq -r '(.download.bandwidth * 8 / 1000000) | round')
UPLOAD_MBPS=$(printf '%s' "$RESULT_JSON" | jq -r '(.upload.bandwidth * 8 / 1000000) | round')
PING_MS=$(printf '%s' "$RESULT_JSON" | jq -r '.ping.latency | round')

if [ -z "$DOWNLOAD_MBPS" ] || [ "$DOWNLOAD_MBPS" = "null" ] ||
   [ -z "$UPLOAD_MBPS" ] || [ "$UPLOAD_MBPS" = "null" ] ||
   [ -z "$PING_MS" ] || [ "$PING_MS" = "null" ]; then
  write_state "$CURRENT_KEY" "$GATEWAY_IP" "fail"
  log "speedtest returned unparseable JSON on network $GATEWAY_IP"
  notify "Speed test result could not be parsed" "Speedtest failed: $NETWORK_LABEL"
  exit 1
fi

write_state "$CURRENT_KEY" "$GATEWAY_IP" "ok"
log "ok network=$GATEWAY_IP ssid=\"$SSID\" down=${DOWNLOAD_MBPS}Mbps up=${UPLOAD_MBPS}Mbps ping=${PING_MS}ms"
notify "Down: ${DOWNLOAD_MBPS} Mbps  Up: ${UPLOAD_MBPS} Mbps  Ping: ${PING_MS} ms" "Speedtest: $NETWORK_LABEL"
