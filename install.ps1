<#
.SYNOPSIS
  Installs the Logitech mouse battery tray utility (mousebat).

.DESCRIPTION
  - Copies mousebat.ps1 + discharge-stats.ps1 + build.ps1 to -InstallDir.
  - Generates a small toast logo (applogo.png).
  - Installs the BurntToast PowerShell module (current user).
  - Builds mousebat.exe (~50 KB, windowless) via build.ps1 (ps2exe).
  - Registers it at logon (single Startup shortcut) and removes any legacy
    LGSTray / watchdog autostart entries from older versions.
  - Launches it.

  mousebat reads battery from Logitech G HUB's local websocket, so G HUB must be
  running. No LGSTray, no bundled runtime: the exe rides on the built-in .NET
  Framework, and the whole install is well under 1 MB.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1
#>
param([string]$InstallDir = "$env:USERPROFILE\Tools\LGSTray")

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# 1. Copy scripts.
foreach ($f in 'mousebat.ps1', 'discharge-stats.ps1', 'build.ps1') {
    Copy-Item (Join-Path $repo $f) $InstallDir -Force
}

# 2. Toast logo (a simple battery-green disc).
Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap 64, 64
$g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.Clear([System.Drawing.Color]::Transparent)
$g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(46, 204, 113))), 2, 2, 59, 59)
$g.Dispose(); $bmp.Save((Join-Path $InstallDir 'applogo.png'), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()

# 3. BurntToast (toast notifications), current user only.
if (-not (Get-Module -ListAvailable -Name BurntToast)) {
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }
    Install-Module BurntToast -Scope CurrentUser -Force -AllowClobber -Confirm:$false
}

# 4. Build the exe.
& (Join-Path $InstallDir 'build.ps1') -OutDir $InstallDir

# 5. Autostart: single Startup shortcut. Remove any legacy LGSTray/watchdog entries.
$startup = [Environment]::GetFolderPath('Startup')
Remove-Item (Join-Path $startup 'LGSTray.lnk'), (Join-Path $startup 'MouseBattery.lnk'), (Join-Path $startup 'lgstray-watchdog.vbs'), (Join-Path $startup 'charge-watch.vbs') -ErrorAction SilentlyContinue
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name LGSTrayGUI -ErrorAction SilentlyContinue
$wsh = New-Object -ComObject WScript.Shell
$lnk = $wsh.CreateShortcut((Join-Path $startup 'mousebat.lnk'))
$lnk.TargetPath = Join-Path $InstallDir 'mousebat.exe'; $lnk.WorkingDirectory = $InstallDir; $lnk.Save()

# 6. Launch.
Start-Process (Join-Path $InstallDir 'mousebat.exe') -WorkingDirectory $InstallDir

Write-Host ("Done ({0} KB exe). Requires Logitech G HUB running." -f [math]::Round((Get-Item (Join-Path $InstallDir 'mousebat.exe')).Length / 1KB))
Write-Host "Stats: powershell -ExecutionPolicy Bypass -File `"$InstallDir\discharge-stats.ps1`""
