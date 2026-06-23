# lgstray — Logitech charge / low-battery notifier + discharge stats (Windows)

Desktop toast notifications when a wireless Logitech mouse:

- **finishes charging** (charge complete), and
- **drops below a low-battery threshold** (default 5%),

plus a **discharge log + analysis** that tells you when the battery is draining
*faster than usual* — accounting for the mouse's sleep mode.

Logitech **G HUB** shows the battery level but never notifies on either event — this fills that gap.

Built and tested with a **Logitech G PRO 2 LIGHTSPEED** (HID++ over a LIGHTSPEED receiver), but works with any wireless Logitech mouse that [LGSTray](https://github.com/andyvorld/LGSTrayBattery) can read.

## How it works

```
Logitech receiver ──HID++──► LGSTray.exe ──HTTP :12321──► MouseBattery.exe ──► BurntToast toast
                                  │                              └────────────► battery-history.csv ──► discharge-stats.ps1
                                  └─ its own tray icon (battery %)
```

- **LGSTray** ([andyvorld/LGSTrayBattery](https://github.com/andyvorld/LGSTrayBattery)) is a third-party tray app that reads battery over HID++ (or the G HUB websocket) and exposes it at `http://localhost:12321/device/<id>` as XML (`battery_percent`, `charging`). It draws its own per-device tray icon.
- **MouseBattery.exe** (compiled from `charge-notify.ps1`) polls that endpoint and:
  - raises toasts via **BurntToast** — *full charge* on the **falling edge** of `charging` while ≥95% (never false-fires at startup), *low battery* when `< LowThresh%` and not charging, **once per drain cycle** (re-arms above 10%);
  - appends `battery-history.csv` (one row per state change) for the stats script.

  It runs **headless** (no tray icon of its own): LGSTray's icon can't be hidden, so a second icon would just be a duplicate. Toggle LGSTray's **"Display Numeric Icon"** menu item if you want the % drawn on its icon.

Both start at logon via plain **Startup shortcuts** — launch-once, no background loop, no auto-restart. If LGSTray crashes it stays down until next logon (no restart by design); `charge-notify.log` records a single **`LGSTray server DOWN`** line naming the matching LGSTray `crashlog_*.log`, and `LGSTray server up` on recovery, so the cause is debuggable without log spam.

## Install

Requires Windows 10/11 with Windows PowerShell 5.1+ (built in). No admin needed.

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

This downloads LGSTray, copies the scripts + config, extracts the toast logo, installs BurntToast (current user), builds `MouseBattery.exe`, registers both at logon via Startup shortcuts, and launches everything. Mice are **auto-discovered** — no device id to configure.

## Discharge stats

```powershell
powershell -ExecutionPolicy Bypass -File .\discharge-stats.ps1
```

Reports, per mouse: **active** drain %/hr (+ runtime per charge), **sleep** drain %/hr (+ idle days), the last few discharge intervals, and a verdict on whether the recent active drain is **faster than usual** vs the baseline.

The mouse sleeps when idle and drains far slower than in use, so a single %/hr is meaningless. Every discharge interval is classified by its rate — below `-SleepThreshold` %/hr is *sleep*, above is *active* — and the anomaly check compares **active drain only**, so idle time never skews it. Rates are duration-weighted; voltage is ignored (the GHub backend reports it as 0). The verdict needs a few active-hours of history each side before it stops saying "need more history".

| Param | Default | Meaning |
|-------|---------|---------|
| `SleepThreshold` | `0.5` | %/hr below this = sleep/idle, above = active use |
| `RecentHours` | `24` | "recent" window for the anomaly check |
| `AnomalyFactor` | `1.4` | recent/baseline active rate at/above this = "faster than usual" |
| `MinActiveHours` | `3` | minimum active-hours each side before a verdict is given |

`battery-history.csv` (`timestamp,name,percent,charging,voltage`) is plot-ready — graphing comes later.

## Configure

Edit the `param(...)` block at the top of `charge-notify.ps1`, then rebuild + restart with `restart-watcher.ps1`:

| Param | Default | Meaning |
|-------|---------|---------|
| `PollSeconds` | `60` | HTTP poll interval |
| `FullMin` | `95.0` | charge-stop at/above this % counts as "full" |
| `LowThresh` | `5.0` | warn below this % |
| `LowRearm` | `10.0` | re-arm the low warning once back above this % |

`appsettings.toml` sets LGSTray's own `pollPeriod = 120` (down from the 600s default) so battery state refreshes every 2 minutes, and enables only the **GHub** backend (Native off) so each mouse is listed once.

## Files

| File | Purpose |
|------|---------|
| `install.ps1` | End-to-end installer (download + build + autostart) |
| `charge-notify.ps1` | The headless watcher: polls battery, toasts, logs CSV (compiled to `MouseBattery.exe`) |
| `build.ps1` | Compiles `charge-notify.ps1` → `MouseBattery.exe` via ps2exe |
| `discharge-stats.ps1` | Discharge-rate stats + "faster than usual?" analysis |
| `restart-watcher.ps1` | Rebuild-free restart of the watcher after edits |
| `appsettings.toml` | LGSTray config (HTTP server on :12321, faster poll, GHub-only) |

The LGSTray binaries and `MouseBattery.exe` are **not** committed (large / built); `install.ps1` fetches and builds them. `battery-history.csv`, logs, and `.armed` are machine-local.

## Notes

- The toast **logo** is the LGSTray battery icon (extracted to `applogo.png` at install). The **top-left sender** stays "Windows PowerShell" — changing that needs a registered AppUserModelID, out of scope here.
- WSL users: everything runs on the Windows host; the watcher and LGSTray live in the interactive Windows session.
