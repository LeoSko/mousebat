<#
.SYNOPSIS
  Installs the native mousebat mouse-battery tray utility.

.DESCRIPTION
  - Compiles mousebat.exe (~30 KB) with the built-in C# compiler (csc.exe).
  - Launches it. The app registers itself to start at logon on first run (toggle
    it from the tray menu); source and build script stay in the repo, so the
    install folder holds only the exe and its runtime data.

  No bundled runtime, no G HUB required: mousebat reads battery directly over
  HID++ (G HUB websocket is only a fallback). Needs Windows 10/11 with the
  .NET Framework 4.x (built in).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1
#>
param([string]$InstallDir = "$env:USERPROFILE\Tools\mousebat")

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

& (Join-Path $repo 'build.ps1') -OutDir $InstallDir
Start-Process (Join-Path $InstallDir 'mousebat.exe') -WorkingDirectory $InstallDir

Write-Host ("Done ({0} KB exe). Autostart on; toggle from the tray menu." -f [math]::Round((Get-Item (Join-Path $InstallDir 'mousebat.exe')).Length / 1KB))
