# lgstray — Logitech mouse battery tray + notifier (Windows)

A **system-tray icon per wireless Logitech mouse** showing its battery **% in a
colour that tracks the level** (green → orange → red, blue while charging), plus
desktop toasts when a mouse:

- **finishes charging** (charge complete), and
- **drops below a low-battery threshold** (default 5%).

Logitech **G HUB** shows the battery level but never notifies on either event, and
doesn't put a live % in the tray — this fills both gaps.

The connected mouse is **auto-discovered** from LGSTray's device list (no hardcoded
device id). Built with a **Logitech G PRO Wireless**, but works with any wireless
Logitech mouse that [LGSTray](https://github.com/andyvorld/LGSTrayBattery) can read.

## How it works

```
Logitech receiver ─► LGSTray.exe ──HTTP :12321──► charge-notify.ps1 ─► tray icon + BurntToast
```

- **LGSTray** ([andyvorld/LGSTrayBattery](https://github.com/andyvorld/LGSTrayBattery)) is a third-party tray app that reads battery over HID++ (or the G HUB websocket) and exposes it at `http://localhost:12321/device/<id>` as XML (`battery_percent`, `charging`).
- **charge-notify.ps1** is a hidden WinForms app that polls that server, and:
  - lists every mouse, **deduped by name**, and draws **one tray icon per mouse**
    with its battery % (grey `?` until LGSTray has a reading);
  - *Full charge* toast fires on the **falling edge** of the `charging` flag while
    ≥95% — so it never false-fires at startup (it must observe `charging=True` first);
  - *Low battery* toast fires when `< LowThresh%` and not charging, **once per drain
    cycle** (re-arms above `LowRearm%`).

### One LGSTray backend, on purpose

`appsettings.toml` enables **only the GHub backend** (`[Native] enabled = false`).
LGSTray's GHub and Native backends each report the same mouse once, so leaving both
on lists every mouse **twice** under different names. GHub is kept because it keeps
reporting while the mouse is idle (the Native HID++ backend goes quiet on an idle
mouse when G HUB owns the device). No G HUB? Flip them — Native on, GHub off.

## Icon legend

| Colour | Meaning |
|--------|---------|
| green  | ≥60% (or full) · orange 30–59% · red <30% · blue charging · grey `?` no reading yet |

The number is the battery %; `F` means full.

## Install

Requires Windows 10/11 with Windows PowerShell 5.1+ (built in). No admin needed.

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

This downloads LGSTray (skipped if already present), copies the scripts + config, extracts the toast logo, installs BurntToast (current user), registers both LGSTray and the watcher to start at logon (Startup folder), and launches them. The mouse is auto-discovered — no device id to set.

## Configure

Edit the `param(...)` block at the top of `charge-notify.ps1`:

| Param | Default | Meaning |
|-------|---------|---------|
| `PollSeconds` | `60` | HTTP poll interval |
| `FullMin` | `95.0` | charge-stop above this % counts as "full" |
| `LowThresh` | `5.0` | warn below this % |
| `LowRearm` | `10.0` | re-arm the low warning once back above this % |

`appsettings.toml` sets LGSTray's own `pollPeriod = 120` (down from the 600s default) so battery state refreshes every 2 minutes.

After editing, restart the watcher: `restart-watcher.ps1` (kills the running watcher, relaunches hidden, fires a test toast).

## Files

| File | Purpose |
|------|---------|
| `install.ps1` | End-to-end installer (download + deploy + autostart) |
| `charge-notify.ps1` | The watcher: polls battery, raises toasts |
| `restart-watcher.ps1` | Restart the watcher after edits |
| `charge-watch.vbs` | Hidden launcher template (install generates the deployed copy with the right path) |
| `appsettings.toml` | LGSTray config (HTTP server on :12321, faster poll) |

The LGSTray binaries themselves are **not** committed (large, third-party); `install.ps1` downloads them.

## Notes

- The toast **logo** is the LGSTray battery icon (extracted to `applogo.png` at install). The **top-left sender** stays "Windows PowerShell" — changing that needs a registered AppUserModelID, out of scope here.
- WSL users: everything runs on the Windows host; the watcher and LGSTray live in the interactive Windows session.
