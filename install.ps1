<#
.SYNOPSIS
  Installs the Logitech charge / low-battery notifier on this Windows machine.

.DESCRIPTION
  - Downloads LGSTray (vendor tray app that exposes battery over a local HTTP
    server) and extracts it to -InstallDir.
  - Copies our config + scripts from this repo.
  - Extracts the app icon to applogo.png for the toast logo.
  - Installs the BurntToast PowerShell module (current user).
  - Builds MouseBattery.exe (the headless notifier) from charge-notify.ps1.
  - Registers ONE hidden watchdog at logon that keeps both LGSTray and
    MouseBattery alive (Startup folder, no admin needed).
  - Launches everything immediately.

  LGSTray draws its own tray icon per device and cannot be told to hide it, so
  MouseBattery runs headless (no icon of its own) and only adds what LGSTray
  lacks: toasts on full/low and a CSV discharge log for discharge-stats.ps1.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1
#>
param(
    [string]$InstallDir = "$env:USERPROFILE\Tools\LGSTray",
    [string]$LgsVersion = "v3.0.3"
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "Installing to $InstallDir"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# 1. Download + extract LGSTray (standalone, self-contained .NET build).
$tag = $LgsVersion.TrimStart('v') -replace '\.','_'
$url = "https://github.com/andyvorld/LGSTrayBattery/releases/download/$LgsVersion/Release_v$tag-standalone.zip"
$zip = Join-Path $InstallDir 'lgstray.zip'
Write-Host "Downloading $url"
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
Expand-Archive -Path $zip -DestinationPath $InstallDir -Force
Remove-Item $zip -Force

# 2. Copy our config + scripts over the defaults.
foreach ($f in 'appsettings.toml', 'charge-notify.ps1', 'build.ps1', 'restart-watcher.ps1', 'lgstray-watchdog.ps1', 'discharge-stats.ps1') {
    Copy-Item (Join-Path $repo $f) $InstallDir -Force
}

# 3. Extract the vendor icon for the toast logo.
Add-Type -AssemblyName System.Drawing
$exe = Join-Path $InstallDir 'LGSTray.exe'
$ico = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
$bmp = $ico.ToBitmap()
$bmp.Save((Join-Path $InstallDir 'applogo.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose(); $ico.Dispose()

# 4. BurntToast (toast notifications), current user only.
if (-not (Get-Module -ListAvailable -Name BurntToast)) {
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }
    Install-Module BurntToast -Scope CurrentUser -Force -AllowClobber -Confirm:$false
}

# 5. Build the headless notifier exe (MouseBattery.exe) from charge-notify.ps1
#    (build.ps1 self-installs ps2exe if needed).
& (Join-Path $InstallDir 'build.ps1') -OutDir $InstallDir

# 6. Autostart: ONE hidden watchdog that keeps LGSTray + MouseBattery alive
#    (no admin; survives the LGSTray dispose-crash a logon shortcut can't).
$startup = [Environment]::GetFolderPath('Startup')
#   Remove any legacy entries from older installs.
Remove-Item (Join-Path $startup 'LGSTray.lnk'), (Join-Path $startup 'MouseBattery.lnk'), (Join-Path $startup 'charge-watch.vbs') -ErrorAction SilentlyContinue
$vbs = @"
' Starts the LGSTray + MouseBattery watchdog hidden at logon (no console flash).
CreateObject("WScript.Shell").Run _
  "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$InstallDir\lgstray-watchdog.ps1""", _
  0, False
"@
Set-Content -Path (Join-Path $startup 'lgstray-watchdog.vbs') -Value $vbs -Encoding ASCII

# 7. Launch now.
Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$startup\lgstray-watchdog.vbs`""

Write-Host "Done. Device list: http://localhost:12321/  (the watcher auto-discovers mice)."
Write-Host "Stats:  powershell -ExecutionPolicy Bypass -File `"$InstallDir\discharge-stats.ps1`""
