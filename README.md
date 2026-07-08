# mousebat

Windows tray utility for wireless Logitech mouse battery. Shows the level in an
animated battery tray icon, sends graduated nudges on low, critical, and full
charge (and on unusually fast drain), and logs history for a chart. Single ~30 KB
exe, nothing to install, G HUB not required.

## Screenshots

Animated battery tray icon, colour-coded by level and charging state:

![tray icon](docs/tray.png)

Thresholds dialog (double-click the tray icon) and battery history chart:

![settings](docs/settings.png) ![chart](docs/chart.png)

## How it works

Reads the battery over HID++ straight from the receiver, so it works with G HUB
closed. If that returns nothing while G HUB is running, it falls back to G HUB's
local websocket. A wireless mouse only reports battery while awake; the last
reading is cached and shown while it sleeps. Runs headless, started once at logon.

The tray icon is a live battery: fill height tracks the charge, colour tracks the
level (green/amber/red), and it animates — a rising wave while charging, a soft
pulse when low or full.

Nudges repeat while the condition holds, at a cadence that tightens as it gets
worse (all thresholds and cadences are configurable):

- Low: below the low threshold (5% default) and discharging, re-nudged every 1%
  dropped; between low and the re-arm level (10% default), every 5% dropped.
- Critical: at 1%, re-nudged every 15 seconds.
- Full charge: charging at or above 95% (default), re-nudged every 5 minutes to
  unplug.
- Fast drain: recent active drain well above your usual rate (sleep time ignored,
  so light vs heavy days don't false-trigger).

Nudges are suppressed while the workstation is locked, and never fire off a stale
reading from a sleeping mouse.

## Install

Needs Windows 10/11 with .NET Framework 4.x (built in). No admin.

Download `mousebat.exe` from the [latest release](../../releases/latest), or build
from source:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

It compiles the exe with `csc.exe` and launches it. On first run it registers
itself to start with Windows.

## Tray menu

- Start with Windows: toggle autostart (the path self-corrects if you move the exe).
- Settings: set the low, re-arm and full percentages plus the nudge cadences (or
  double-click the icon).
- Battery chart: render and open a chart of the history (also `mousebat.exe -Chart`).

## Files

| File | Purpose |
|------|---------|
| `mousebat.cs` | The app: reader, tray icon, notifications, CSV, chart, settings |
| `build.ps1` | Compiles `mousebat.cs` to `mousebat.exe` with `csc.exe` |
| `install.ps1` | Build and launch |

## Releases

Push a `v*` tag and GitHub Actions builds the exe and attaches it to a release:

```bash
git tag v1.1.0 && git push github v1.1.0
```
