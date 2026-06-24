# mousebat — Logitech mouse battery tray utility (Windows)

A tiny **~26 KB native** tray utility for wireless Logitech mice:

- one **tray icon** showing battery % (colour-coded by level / charging),
- **toast notifications** on **full charge** and **low battery** (configurable),
- a **CSV history** with a **battery chart** and a **discharge-rate analysis**
  ("is it draining faster than usual?").

Logitech **G HUB** shows the level but never notifies — this fills that gap, in a
single windowless exe with **no PowerShell host, no bundled runtime, and no G HUB
dependency**.

## How it works

```
Logitech receiver ──HID++ (USB HID)──►┐
                                       ├─► mousebat.exe ──► tray icon + toast + battery-history.csv
G HUB agent ──ws://127.0.0.1:9010────►┘   (HID++ first; G HUB only as fallback)
```

- **mousebat.exe** (compiled from `mousebat.cs` with the built-in C# compiler)
  reads the battery two ways:
  1. **HID++ directly** from the receiver (feature `0x1001` voltage → % via the
     Solaar/LGSTray lookup) — needs no G HUB, works with it closed.
  2. if HID++ returns nothing (and G HUB is running), it falls back to the **G HUB
     agent's local websocket**.
  Then it draws the tray icon, raises toasts (native balloon → Action Center), and
  logs the CSV.
  - *Full charge* fires on the **falling edge** of `charging` while ≥ `FullMin`%
    (never false-fires at startup); *low battery* fires below `LowThresh`% and not
    charging, **once per drain cycle** (re-arms above `LowRearm`%).
  - A wireless mouse only reports battery while **awake** — asleep/off, *neither*
    HID++ nor G HUB returns anything (true of every tool, LGSTray included). The
    last reading is cached to `battery-state.json` (seeded from the CSV at startup)
    and shown meanwhile, so the icon always has a value; it refreshes on use.
- It runs **headless**, started **once at logon** by a Startup shortcut — no
  background loop, no watchdog, no auto-restart.

This is the end of an evolution that began with the 226 MB third-party **LGSTray**
bundle: framework-dependent LGSTray (~5 MB) → a ps2exe PowerShell tray app (~56 KB)
→ this native C# exe (~26 KB).

## Install

Requires Windows 10/11 with the **.NET Framework 4.x** (built in) — that's it. No
admin, no downloads, G HUB optional.

Grab `mousebat.exe` from the [latest release](../../releases/latest) (built by CI),
or build from source:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

## CI / releases

GitHub Actions (`.github/workflows/release.yml`) compiles `mousebat.exe` on a
`windows-latest` runner for every push (uploaded as an artifact). Push a tag like
`v1.0.0` to publish a GitHub Release with the exe attached:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

Copies the source, compiles `mousebat.exe` via `csc.exe`, registers it at logon
(removing any legacy LGSTray/watchdog autostart), and launches it. Mice are
auto-discovered.

## Settings, chart, stats

- **Thresholds**: **double-click the tray icon** (or right-click → Settings…) to
  set Low / Re-arm / Full %, saved to `mousebat-settings.json`.
- **Chart**: tray → **Battery chart** (renders `battery-chart.png` from the CSV),
  or `mousebat.exe -Chart`.
- **Discharge analysis**: `powershell -File discharge-stats.ps1` — active drain
  %/hr (+ runtime per charge), sleep drain %/hr, and a faster-than-usual verdict.
  Each interval is classified active vs sleep (< `-SleepThreshold` %/hr = sleep)
  and the anomaly check uses **active intervals only**, so idle time never skews it.

## Files

| File | Purpose |
|------|---------|
| `mousebat.cs` | The utility: HID++/G HUB reader, tray icon, toasts, CSV, chart, settings |
| `build.ps1` | Compiles `mousebat.cs` → `mousebat.exe` via `csc.exe` |
| `discharge-stats.ps1` | Discharge-rate stats + "faster than usual?" analysis |
| `install.ps1` | Compile + autostart installer |

`mousebat.exe`, `battery-history.csv`, `battery-state.json`, `battery-chart.png`,
`mousebat-settings.json`, logs and `.armed` are generated locally and not committed.

## Notes

- Toasts use the tray icon's balloon (Windows routes it to the Action Center); no
  custom app logo.
- WSL users: everything runs on the Windows host.
