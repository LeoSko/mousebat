# lgstray — Logitech charge / low-battery notifier (Windows)

Desktop toast notifications when a wireless Logitech mouse:

- **finishes charging** (charge complete), and
- **drops below a low-battery threshold** (default 5%).

Logitech **G HUB** shows the battery level but never notifies on either event — this fills that gap.

Built and tested with a **Logitech G PRO 2 LIGHTSPEED** (HID++ over a LIGHTSPEED receiver), but works with any wireless Logitech mouse that [LGSTray](https://github.com/andyvorld/LGSTrayBattery) can read.

## How it works

```
Logitech receiver ──HID++──► LGSTray.exe ──HTTP :12321──► charge-notify.ps1 ──► BurntToast toast
```

- **LGSTray** ([andyvorld/LGSTrayBattery](https://github.com/andyvorld/LGSTrayBattery)) is a third-party tray app that reads battery over HID++ (or the G HUB websocket) and exposes it at `http://localhost:12321/device/<id>` as XML (`battery_percent`, `charging`).
- **charge-notify.ps1** polls that endpoint and raises toasts via the **BurntToast** module:
  - *Full charge* fires on the **falling edge** of the `charging` flag while ≥95% — so it never false-fires at startup (it must observe `charging=True` first).
  - *Low battery* fires when `< LowThresh%` and not charging, **once per drain cycle** (re-arms above 10%).

## Install

Requires Windows 10/11 with Windows PowerShell 5.1+ (built in). No admin needed.

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

This downloads LGSTray, copies the scripts + config, extracts the toast logo, installs BurntToast (current user), registers both LGSTray and the watcher to start at logon (Startup folder), and launches them.

Then open <http://localhost:12321/> to confirm your device, and if its id is not `dev00000001`, set it at the top of `charge-notify.ps1` (the deployed copy under `%USERPROFILE%\Tools\LGSTray`).

## Configure

Edit the `param(...)` block at the top of `charge-notify.ps1`:

| Param | Default | Meaning |
|-------|---------|---------|
| `DeviceId` | `dev00000001` | LGSTray device id (from the device list page) |
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
