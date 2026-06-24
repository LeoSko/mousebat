# mousebat

Windows tray utility for wireless Logitech mouse battery. Shows the level in the
tray, notifies on full charge and low battery, and logs history for a chart and
discharge analysis. Single ~26 KB exe, nothing to install, G HUB not required.

## How it works

Reads the battery over HID++ straight from the receiver, so it works with G HUB
closed. If that returns nothing while G HUB is running, it falls back to G HUB's
local websocket. A wireless mouse only reports battery while awake; the last
reading is cached and shown while it sleeps. Runs headless, started once at logon.

Notifications:

- Full charge: charging stops at or above 95% (default).
- Low battery: below 5% (default) and not charging, once per drain cycle.

## Install

Needs Windows 10/11 with .NET Framework 4.x (built in). No admin.

Download `mousebat.exe` from the [latest release](../../releases/latest), or build
from source:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

It compiles the exe with `csc.exe` and registers it to start at logon.

## Settings, chart, stats

- Thresholds: double-click the tray icon (or right-click, Settings) to set the
  low, re-arm and full percentages.
- Chart: tray menu "Battery chart", or run `mousebat.exe -Chart`.
- Discharge analysis: `powershell -File discharge-stats.ps1` reports active vs
  sleep drain rate and whether recent drain is faster than usual.

## Files

| File | Purpose |
|------|---------|
| `mousebat.cs` | The app: reader, tray icon, toasts, CSV, chart, settings |
| `build.ps1` | Compiles `mousebat.cs` to `mousebat.exe` with `csc.exe` |
| `install.ps1` | Build and register at logon |
| `discharge-stats.ps1` | Discharge-rate analysis |

## Releases

GitHub Actions builds the exe on every push. Push a `v*` tag to publish a release
with the exe attached:

```bash
git tag v1.1.0 && git push github v1.1.0
```
