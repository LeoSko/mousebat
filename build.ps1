<#
.SYNOPSIS
  Compiles the mouse battery utility into a single windowless exe via ps2exe.

.DESCRIPTION
  Builds mousebat.exe from mousebat.ps1 with -noConsole so there is no PowerShell
  window. The script is minified first (comments/blank lines/indentation stripped)
  so the embedded copy is smaller -- ps2exe stores it as UTF-16, so every byte of
  source costs two in the exe. mousebat.ps1 stays the readable source.
#>
param(
    [string]$OutDir  = $PSScriptRoot,
    [string]$ExeName = 'mousebat.exe'
)
$ErrorActionPreference = 'Stop'
$env:LIB = ""; $env:LIBPATH = ""; $env:INCLUDE = ""

# Strip comments, blank lines and indentation. Tracks the one C# here-string
# (Add-Type) so its terminator stays at column 0; C# is whitespace-insensitive so
# its lines get trimmed too. Inline comments are left alone (safe vs '#' in strings).
function Compress-Script([string]$path) {
    $out = New-Object System.Collections.Generic.List[string]
    $inHere = $false
    foreach ($ln in (Get-Content -LiteralPath $path)) {
        $t = $ln.Trim()
        if ($inHere) {
            if ($t -eq "'@" -or $t -eq '"@') { $inHere = $false; $out.Add($t); continue }  # terminator at col 0
            if ($t -eq '' -or $t.StartsWith('//')) { continue }
            $out.Add($t); continue
        }
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $out.Add($t)
        if ($t -match "@['""]$") { $inHere = $true }
    }
    return ($out -join "`r`n")
}

if (-not (Get-Module -ListAvailable ps2exe)) {
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber -Confirm:$false
}
Import-Module ps2exe

$tmp = Join-Path ([IO.Path]::GetTempPath()) 'mousebat.min.ps1'
Set-Content -Path $tmp -Value (Compress-Script (Join-Path $PSScriptRoot 'mousebat.ps1')) -Encoding UTF8

$out = Join-Path $OutDir $ExeName
# -supportOS embeds a Win10/11 compatibility manifest so OSVersion is reported truthfully
# (else the exe looks like "Windows 8" and BurntToast refuses to load).
Invoke-ps2exe -inputFile $tmp -outputFile $out -noConsole -STA -supportOS `
    -title 'Mouse Battery' -description 'Logitech mouse battery tray (HID++/GHub)' -company 'tools8250722' | Out-Null
Remove-Item $tmp -ErrorAction SilentlyContinue

if (Test-Path $out) { "built $out ({0} KB)" -f [math]::Round((Get-Item $out).Length / 1KB) }
else { throw 'build failed' }
