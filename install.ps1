<#
.SYNOPSIS
  Installs the native mousebat mouse-battery tray utility.

.DESCRIPTION
  - Copies mousebat.cs + build.ps1 + discharge-stats.ps1 to -InstallDir.
  - Compiles mousebat.exe (~26 KB) with the built-in C# compiler (csc.exe).
  - Registers it at logon (single Startup shortcut) and removes any legacy
    LGSTray / watchdog / ps2exe autostart entries from older versions.
  - Launches it.

  No PowerShell host, no BurntToast, no bundled runtime, no G HUB required:
  mousebat reads battery directly over HID++ (G HUB websocket is only a fallback).
  Needs Windows 10/11 with the .NET Framework 4.x (built in).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1
#>
param([string]$InstallDir = "$env:USERPROFILE\Tools\LGSTray")

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# 1. Compile the exe straight into InstallDir (source + build stay in the repo,
#    so the install folder holds only the exe + the stats tool + runtime data).
& (Join-Path $repo 'build.ps1') -OutDir $InstallDir
Copy-Item (Join-Path $repo 'discharge-stats.ps1') $InstallDir -Force

# 2. Autostart: single Startup shortcut. Remove legacy entries from older installs.
$startup = [Environment]::GetFolderPath('Startup')
Remove-Item (Join-Path $startup 'LGSTray.lnk'), (Join-Path $startup 'MouseBattery.lnk'), (Join-Path $startup 'lgstray-watchdog.vbs'), (Join-Path $startup 'charge-watch.vbs') -ErrorAction SilentlyContinue
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name LGSTrayGUI -ErrorAction SilentlyContinue
$wsh = New-Object -ComObject WScript.Shell
$lnk = $wsh.CreateShortcut((Join-Path $startup 'mousebat.lnk'))
$lnk.TargetPath = Join-Path $InstallDir 'mousebat.exe'; $lnk.WorkingDirectory = $InstallDir; $lnk.Save()

# 3. Launch.
Start-Process (Join-Path $InstallDir 'mousebat.exe') -WorkingDirectory $InstallDir

Write-Host ("Done ({0} KB exe). Stats: powershell -File `"$InstallDir\discharge-stats.ps1`"" -f [math]::Round((Get-Item (Join-Path $InstallDir 'mousebat.exe')).Length / 1KB))
