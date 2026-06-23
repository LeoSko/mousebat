# Keeps the two pieces alive: LGSTray.exe (battery HTTP server on :12321) and
# MouseBattery.exe (the tray notifier that polls it). Started hidden at logon by
# lgstray-watchdog.vbs. If either exits or crashes, this relaunches it within ~60s
# (LGSTray has a known dispose crash; a Startup shortcut alone never restarts it).
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path

$targets = @(
    @{ Name = 'LGSTray';      Exe = Join-Path $dir 'LGSTray.exe' }
    @{ Name = 'MouseBattery'; Exe = Join-Path $dir 'MouseBattery.exe' }
)

while ($true) {
    foreach ($t in $targets) {
        if (-not (Get-Process -Name $t.Name -ErrorAction SilentlyContinue)) {
            Start-Process -FilePath $t.Exe -WorkingDirectory $dir
            if ($t.Name -eq 'LGSTray') { Start-Sleep -Seconds 8 }  # let the HTTP server bind before MouseBattery polls
        }
    }
    Start-Sleep -Seconds 60
}
