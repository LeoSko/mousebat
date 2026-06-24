# mousebat

Windows tray utility for wireless Logitech mouse battery. Shows the level in the
tray, notifies on full charge, low battery, and unusually fast drain, and logs
history for a chart. Single ~30 KB exe, nothing to install, G HUB not required.

## How it works

Reads the battery over HID++ straight from the receiver, so it works with G HUB
closed. If that returns nothing while G HUB is running, it falls back to G HUB's
local websocket. A wireless mouse only reports battery while awake; the last
reading is cached and shown while it sleeps. Runs headless, started once at logon.

Notifications:

- Full charge: charging stops at or above 95% (default).
- Low battery: below 5% (default) and not charging, once per drain cycle.
- Fast drain: recent active drain well above your usual rate (sleep time ignored,
  so light vs heavy days don't false-trigger).

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
- Settings: set the low, re-arm and full percentages (or double-click the icon).
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
