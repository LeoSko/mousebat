# Kill any running watcher (exe or the old .ps1 form), relaunch the exe, fire a demo toast.
$exe = Join-Path $PSScriptRoot 'MouseBattery.exe'

Get-Process MouseBattery -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    "killed exe PID $($_.Id)"
}
Get-CimInstance Win32_Process -Filter 'Name="powershell.exe"' |
    Where-Object { $_.CommandLine -match 'charge-notify' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; "killed ps1 PID $($_.ProcessId)" }

Start-Sleep -Seconds 1
if (Test-Path $exe) { Start-Process -FilePath $exe -WorkingDirectory $PSScriptRoot }
else { "MouseBattery.exe not found - run build.ps1 or install.ps1 first" }
Start-Sleep -Seconds 3

$new = Get-Process MouseBattery -ErrorAction SilentlyContinue
if ($new) { "watcher running PID $($new.Id)" } else { "watcher NOT running" }

Import-Module BurntToast -ErrorAction SilentlyContinue
$logo = Join-Path $PSScriptRoot 'applogo.png'
if (Get-Module BurntToast) {
    if (Test-Path $logo) { New-BurntToastNotification -Text 'Mouse battery watcher restarted', 'Tray icon refreshed.' -AppLogo $logo -UniqueIdentifier 'lg-restart' }
    else                 { New-BurntToastNotification -Text 'Mouse battery watcher restarted', 'Tray icon refreshed.' -UniqueIdentifier 'lg-restart' }
    'demo toast fired'
}
