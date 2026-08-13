# wifi-speedtest-notifier

Whenever you join a new Wi-Fi network or sign back into your computer, get an automatic notification with Ookla speed test results.

<img width="604" height="97" alt="Speedtest: WIFI_NAME Down: 677 Mbps  Up: 40 Mbps  Ping: 13 ms" src="https://github.com/user-attachments/assets/5a8bd048-bde5-4d70-b205-641086fbeb71" />

## Install

### macOS only - no other OSes currently supported

Requires [Homebrew](https://brew.sh) to already be installed.

1. Clone this repo and `cd` into it:

   ```sh
   git clone https://github.com/brianliu-ucsd/wifi-speedtest-notifier.git
   cd wifi-speedtest-notifier
   ```

2. Run the installer

   ```sh
   ./install.sh
   ```

   If you get a "permission denied" error, the script isn't marked
   executable yet. Fix it with `chmod +x install.sh` and try again.

This installs `jq` and the Ookla `speedtest` CLI if you don't already have
them, registers a per-user LaunchAgent, and runs one test immediately
against whatever network you're currently on so you can confirm it works.

### [Optional] Show the real network name

> This step is optional! It is purely for cosmetic purposes; no functionality is compromised by 
> choosing to do or not do the below steps. 

By default, macOS blocks background scripts from reading a Wi-Fi network's
name, so notifications show the gateway's IP address e.g. "Speedtest:
192.168.50.1" instead of "Speedtest: WIFI_NAME". To show the real Wi-Fi name, follow the below steps. 

1. Open the **Shortcuts** app > **File** > **New Shortcut**.
2. Add the **Get Network Details** action, and set it to **Wi-Fi** /
   **Network Name**.
3. Add the **Stop and Output** action.
3. Rename the shortcut to **`Get Wi-Fi SSID`** (must match exactly).

<img width="891" height="233" alt="shortcut" src="https://github.com/user-attachments/assets/7dff4da0-6a17-46aa-b2c6-758d64d63cca" />

No reinstall needed - `wifi-speedtest.sh` picks it up on its next run. The
first run afterward may prompt for a Location Services permission; allow it.
If anything about this ever stops working, notifications just fall back to
the IP address - nothing else is affected.

## How it works

A LaunchAgent runs the check when you join a new network, when you log in,
and every 5 minutes as a safety net. Each time, it:

1. Confirms you're actually on Wi-Fi (not Ethernet or offline).
2. Identifies the network by its gateway, so it works the same whether or
   not you've added the optional Shortcut above.
3. Skips testing again if you're still on a network it already tested
   successfully. If the last test on this network failed (e.g. a captive
   portal you hadn't logged into yet), it retries.
4. Runs the speed test and shows a notification with download, upload, and
   ping.

Logs, if you want to check on it:

- `~/Library/Logs/wifi-speedtest.log` - one line per test run (or skip/error).
- `~/Library/Logs/wifi-speedtest.launchd.log` - launchd/script stderr.

## Known limitation

- Roaming between access points on the same physical network (mesh Wi-Fi,
  hotel/campus networks sharing one gateway) isn't detected as a network
  change so under current functionality no new speedtest will be run. 

## Uninstall

```sh
./uninstall.sh
```

Stops and removes the LaunchAgent. Logs and cached state are left in place;
delete them yourself (see paths above) if you want a clean slate.
