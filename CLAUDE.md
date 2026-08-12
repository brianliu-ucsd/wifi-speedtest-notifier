# wifi-speedtest-notifier

Agent-facing notes: design rationale and maintenance context that isn't
needed to install or use the tool (that's in `README.md`). Read this before
making structural changes.

## Layout

- `wifi-speedtest.sh` - the job launchd runs. Detects a Wi-Fi network change
  and runs `speedtest` when one happens.
- `install.sh` / `uninstall.sh` - render the plist template, register/remove
  the LaunchAgent.
- `com.wifispeedtest.notifier.plist.template` - has `__SCRIPT_PATH__` and
  `__LOG_PATH__` placeholders filled in by `install.sh` at install time.

## Design decisions

**Gateway MAC instead of SSID.** The original design read the SSID directly.
Testing on a real machine (macOS 26 "Tahoe") found `networksetup`,
`ipconfig`, `system_profiler`, and `wdutil` all redact SSID/BSSID behind
Location Services, and `sudo`/root does not bypass it - confirmed by hand on
that machine, not documented anywhere. Whether this is Tahoe-specific or
holds on earlier macOS versions is untested. If a future OS version exposes
the SSID again, this is the place to revisit that tradeoff (see README
"Install" for the fallback that was shipped instead, and the design note
below for the follow-up SSID-via-Shortcut workaround).

**SSID via a manually-built Shortcut, as a cosmetic opt-in only.** The
Shortcuts app's "Get Network Details" action can read the SSID where
Terminal-launched tools can't, because Shortcuts.app itself carries the
Location Services entitlement - confirmed by hand on this machine (macOS 26
"Tahoe" 26.5.2): a real `launchd`-triggered run of `shortcuts run "Get Wi-Fi
SSID"` returned the correct SSID in ~0.1s with no visible permission prompt
at all (the interactive first run apparently didn't need one either - why is
unconfirmed, `TCC.db` isn't readable without Full Disk Access). A missing
shortcut fails in ~0.07s with a clean nonzero exit, not a hang - confirmed
by hand, not documented anywhere.

This stays cosmetic, not structural: `get_ssid()` in `wifi-speedtest.sh`
only feeds the notification/log label, never `CURRENT_KEY` (still the
gateway MAC, per the design decision above). Two things ruled out the
alternative of shipping a ready-to-import `.shortcut` file instead of asking
users to build it by hand:
- The `shortcuts` CLI (`run`/`list`/`view`/`sign`) has no `create` or
  `export` subcommand - a shortcut can only be authored through the GUI.
- Driving the GUI headlessly (AppleScript/System Events) and reading
  `~/Library/Shortcuts` to pull out the built file both hit TCC walls
  (Accessibility and Full Disk Access respectively) that can't be granted
  non-interactively - and asking a user to grant those just so *we* could
  automate a 60-second task they can do directly is worse UX than having
  them do it directly.

If Apple ever ships a `shortcuts create` (or similar) subcommand, revisit
shipping a pre-built `.shortcut` file so this needs zero manual steps.

**mkdir as a lock, not `flock`.** macOS ships no `flock` binary out of the
box. `mkdir` is atomic on POSIX filesystems, so `wifi-speedtest.sh` uses a
lock *directory* instead of a lock file. Stale locks (from a crashed run)
are cleared if older than 5 minutes - see the lock block in
`wifi-speedtest.sh`.

**Three launchd triggers, not one.** `WatchPaths` is undocumented OS
behavior (Apple's own `launchd.plist(5)` man page calls filesystem event
monitoring "highly race-prone" and warns modifications can be missed).
`RunAtLoad` only fires at login/fresh-start, not on wake. `StartInterval` is
a poll that's skipped (not queued) if the Mac is asleep at the scheduled
tick. None of the three is individually reliable; together they bound
worst-case detection lag to ~5 minutes.

## Maintenance & blast radius

What breaks this tool, and how far the damage spreads:

- **Ookla CLI changes its JSON schema** (e.g. renames `.download.bandwidth`)
  - isolated to the three `jq` lines in `wifi-speedtest.sh`. Everything else
  (locking, network detection, notification delivery) is untouched. Lowest
  risk, easiest to fix.
- **Homebrew retires/renames the `teamookla/speedtest` tap** - isolated to
  the `brew tap`/`brew trust` lines in `install.sh`. The main script only
  calls the `speedtest` binary by name on `PATH`, so even a manual install
  of the binary would keep the rest of the tool working unchanged.
- **A macOS update changes `WatchPaths` behavior** - already partially
  happened once (the SSID redaction above). If a future macOS version stops
  honoring `WatchPaths` on `/Library/Preferences/SystemConfiguration`
  entirely, the design degrades gracefully on its own: the `StartInterval`
  safety-net poll keeps the tool functioning with up to 5 minutes of lag,
  zero code changes required.
- **A future macOS update further locks down `route`/`arp` output** - the
  one real structural risk, since gateway-MAC detection leans on that layer
  staying unprivileged. Low probability (basic POSIX networking primitives,
  not Apple-specific privacy surface like SSID/BSSID), but if it happened
  there'd be no unprivileged fallback left - a rethink, not a patch.

## Conventions

- Script comments should explain non-obvious *why* (races, OS quirks,
  platform gaps) - not restate what's already in the README, and not record
  findings specific to one developer's machine. Put investigation history
  and rationale here instead.
- No test suite exists yet. If one gets built, group by
  script/category first, then order simple-to-complex within each group.
