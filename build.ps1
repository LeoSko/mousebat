<#
.SYNOPSIS
  Compiles the mouse battery utility into a single windowless exe via ps2exe.

.DESCRIPTION
  Builds mousebat.exe from mousebat.ps1 with -noConsole so there is no PowerShell
  window. The result is ~50 KB and relies only on the built-in .NET Framework.
#>
param(
    [string]$OutDir  = $PSScriptRoot,
    [string]$ExeName = 'mousebat.exe'
)
$ErrorActionPreference = 'Stop'
$env:LIB = ""; $env:LIBPATH = ""; $env:INCLUDE = ""

if (-not (Get-Module -ListAvailable ps2exe)) {
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber -Confirm:$false
}
Import-Module ps2exe

$out = Join-Path $OutDir $ExeName
# -supportOS embeds a Win10/11 compatibility manifest so OSVersion is reported truthfully
# (else the exe looks like "Windows 8" and BurntToast refuses to load).
Invoke-ps2exe -inputFile (Join-Path $PSScriptRoot 'mousebat.ps1') -outputFile $out -noConsole -STA -supportOS `
    -title 'Mouse Battery' -description 'Logitech mouse battery tray (G HUB)' -company 'tools8250722' | Out-Null

if (Test-Path $out) { "built $out ({0} KB)" -f [math]::Round((Get-Item $out).Length / 1KB) }
else { throw 'build failed' }
