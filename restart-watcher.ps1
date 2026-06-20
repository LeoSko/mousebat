# Kill any running watcher, relaunch hidden, fire a demo toast with the new logo.
$procs = Get-CimInstance Win32_Process -Filter 'Name="powershell.exe"'
$procs | Where-Object { $_.CommandLine -match 'charge-notify' } | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    "killed old watcher PID $($_.ProcessId)"
}
Start-Sleep -Seconds 1
$su = [Environment]::GetFolderPath('Startup')
Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$su\charge-watch.vbs`""
Start-Sleep -Seconds 3
$new = Get-CimInstance Win32_Process -Filter 'Name="powershell.exe"' | Where-Object { $_.CommandLine -match 'charge-notify' }
if ($new) { "watcher running PID $($new.ProcessId)" } else { "watcher NOT running" }

Import-Module BurntToast
$logo = Join-Path $PSScriptRoot 'applogo.png'
if (Test-Path $logo) { New-BurntToastNotification -Text 'Logo test', 'Mouse battery alerts now use this icon.' -AppLogo $logo -UniqueIdentifier 'lg-logotest' }
else                 { New-BurntToastNotification -Text 'Logo test', 'Mouse battery alerts now use this icon.' -UniqueIdentifier 'lg-logotest' }
'demo toast fired'
