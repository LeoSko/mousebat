# mousebat — Logitech mouse battery tray utility (Windows)

A single ~50 KB tray utility for wireless Logitech mice:

- one **tray icon** showing battery % (colour-coded by level / charging),
- **toast notifications** on **full charge** and **low battery** (default 5%),
- a **CSV history** of every reading, with a **battery chart** and a
  **discharge-rate analysis** ("is it draining faster than usual?").

Logitech **G HUB** shows the level but never notifies — this fills that gap, in
a single windowless exe with **no bundled runtime** (the whole install is well
under 1 MB).

## How it works

```
Logitech receiver ──HID++ (USB HID)──►┐
                                       ├─► mousebat.exe ──► tray icon + BurntToast toast + battery-history.csv
G HUB agent ──ws://127.0.0.1:9010────►┘   (HID++ first; G HUB only as fallback)
```

- **mousebat.exe** (compiled from `mousebat.ps1`) reads the battery two ways:
  1. **HID++ directly** from the receiver (feature `0x1001` voltage → % via the
     Solaar/LGSTray lookup) — needs no G HUB, works even with it closed.
  2. if HID++ returns nothing (and G HUB is running), it falls back to the **G HUB
     agent's local websocket**.
  It then draws the tray icon, raises toasts, and logs the CSV.
  - *Full charge* fires on the **falling edge** of `charging` while ≥95% (never
    false-fires at startup); *low battery* fires below `LowThresh%` and not
    charging, **once per drain cycle** (re-arms above 10%).
  - A wireless mouse only reports battery while **awake** — when it's asleep/off,
    *neither* HID++ nor G HUB returns anything (true of every tool, LGSTray
    included). The last reading is cached to `battery-state.json` and shown
    meanwhile, so the icon always has a value; it refreshes when the mouse is used.
- It runs **headless** (no console) and is started **once at logon** by a Startup
  shortcut — no background loop, no watchdog, no auto-restart.

This replaces an earlier design that bundled the third-party **LGSTray** app
(~220 MB self-contained / ~5 MB framework-dependent); reading the device directly
removed that dependency entirely.

## Install

Requires Windows 10/11 with Windows PowerShell 5.1+ (built in). G HUB is **not**
required (HID++ reads the device directly); it's only used as a fallback if
present. No admin, no .NET download (the ps2exe build rides on the built-in .NET
Framework).

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

This copies the scripts, generates a toast logo, installs BurntToast, builds
`mousebat.exe`, registers it at logon (and removes any legacy LGSTray/watchdog
autostart), then launches it. Mice are auto-discovered.

## Battery chart + stats

- **Chart**: right-click the tray icon → **Battery chart** (renders
  `battery-chart.png` from the CSV and opens it). Or run
  `mousebat.exe -Chart`.
- **Discharge analysis**:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\discharge-stats.ps1
  ```

  Reports active drain %/hr (+ runtime per charge), sleep drain %/hr, and whether
  recent active drain is **faster than usual** vs baseline. The mouse sleeps when
  idle and drains far slower than in use, so each interval is classified active
  vs sleep (< `-SleepThreshold` %/hr = sleep) and the anomaly check uses **active
  intervals only**, so idle time never skews it.

## Configure

Edit the `$script:Full/Low...` values near the top of `mousebat.ps1`, then rebuild
with `build.ps1`:

| Setting | Default | Meaning |
|---------|---------|---------|
| `FullMin` | `95.0` | charge-stop at/above this % counts as "full" |
| `LowThresh` | `5.0` | warn below this % |
| `LowRearm` | `10.0` | re-arm the low warning once back above this % |
| poll interval | `60 s` | `$script:Timer.Interval` |

## Files

| File | Purpose |
|------|---------|
| `mousebat.ps1` | The utility: reads G HUB, tray icon, toasts, CSV, chart (compiled to `mousebat.exe`) |
| `build.ps1` | Compiles `mousebat.ps1` → `mousebat.exe` via ps2exe |
| `discharge-stats.ps1` | Discharge-rate stats + "faster than usual?" analysis |
| `install.ps1` | Build + autostart installer |

`mousebat.exe`, `battery-history.csv`, `battery-state.json`, `battery-chart.png`,
logs, and `.armed` are generated locally and not committed.

## Notes

- The toast **sender** stays "Windows PowerShell" — changing it needs a registered
  AppUserModelID, out of scope here.
- WSL users: everything runs on the Windows host.
