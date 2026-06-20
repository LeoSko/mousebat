<#
.SYNOPSIS
  Installs the Logitech charge / low-battery notifier on this Windows machine.

.DESCRIPTION
  - Downloads LGSTray (vendor tray app that exposes battery over a local HTTP
    server) and extracts it to -InstallDir.
  - Copies the watcher script + tweaked appsettings.toml from this repo.
  - Extracts the app icon to applogo.png for the toast logo.
  - Installs the BurntToast PowerShell module (current user).
  - Registers both LGSTray and the watcher to start at logon (Startup folder,
    no admin needed).
  - Launches both immediately.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1
#>
param(
    [string]$InstallDir = "$env:USERPROFILE\Tools\LGSTray",
    [string]$LgsVersion = "v3.0.3",
    [int]$LowThreshold  = 5
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "Installing to $InstallDir"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# 1. Download + extract LGSTray (standalone, self-contained .NET build).
#    Skip if it's already here so a redeploy doesn't re-pull ~150 MB.
$exe = Join-Path $InstallDir 'LGSTray.exe'
if (-not (Test-Path $exe)) {
    $tag = $LgsVersion.TrimStart('v') -replace '\.','_'
    $url = "https://github.com/andyvorld/LGSTrayBattery/releases/download/$LgsVersion/Release_v$tag-standalone.zip"
    $zip = Join-Path $InstallDir 'lgstray.zip'
    Write-Host "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $InstallDir -Force
    Remove-Item $zip -Force
} else {
    Write-Host "LGSTray already present, skipping download"
}

# 2. Copy our config + scripts over the defaults.
Copy-Item (Join-Path $repo 'appsettings.toml')    $InstallDir -Force
Copy-Item (Join-Path $repo 'charge-notify.ps1')    $InstallDir -Force
Copy-Item (Join-Path $repo 'restart-watcher.ps1')  $InstallDir -Force

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

# 5. Autostart via the Startup folder (runs in the interactive session, no admin).
$startup = [Environment]::GetFolderPath('Startup')

#   5a. LGSTray server shortcut.
$wsh = New-Object -ComObject WScript.Shell
$lnk = $wsh.CreateShortcut((Join-Path $startup 'LGSTray.lnk'))
$lnk.TargetPath       = $exe
$lnk.WorkingDirectory = $InstallDir
$lnk.Save()

#   5b. Hidden launcher for the watcher (no console flash).
$vbs = @"
' Launches the Logitech charge/low watcher hidden (no console flash) at logon.
CreateObject("WScript.Shell").Run _
  "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ""$InstallDir\charge-notify.ps1""", _
  0, False
"@
Set-Content -Path (Join-Path $startup 'charge-watch.vbs') -Value $vbs -Encoding ASCII

# 6. Launch now.
Start-Process -FilePath $exe -WorkingDirectory $InstallDir
Start-Sleep -Seconds 8
Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$startup\charge-watch.vbs`""

Write-Host "Done. Verify the device list at http://localhost:12321/ and set the"
Write-Host "matching device id at the top of $InstallDir\charge-notify.ps1 if it is not dev00000001."
