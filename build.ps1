<#
.SYNOPSIS
  Compiles mousebat.cs into a native windowless exe with the built-in C# compiler.

.DESCRIPTION
  csc.exe (shipped with the .NET Framework on every Windows) produces a ~26 KB
  exe. Extra references beyond the csc defaults:
  System.Web.Extensions (JavaScriptSerializer, for G HUB JSON) and
  System.Windows.Forms.DataVisualization (the battery chart).
#>
param(
    [string]$OutDir  = $PSScriptRoot,
    [string]$ExeName = 'mousebat.exe'
)
$ErrorActionPreference = 'Stop'
$env:LIB = ""; $env:LIBPATH = ""; $env:INCLUDE = ""   # ignore leaked VS toolchain vars

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw "csc.exe not found (need .NET Framework 4.x)" }

$src = Join-Path $PSScriptRoot 'mousebat.cs'
$out = Join-Path $OutDir $ExeName

& $csc /nologo /optimize+ /target:winexe "/out:$out" `
    /reference:System.Web.Extensions.dll `
    /reference:System.Windows.Forms.DataVisualization.dll `
    $src
if ($LASTEXITCODE -ne 0) { throw "csc failed (exit $LASTEXITCODE)" }
if (Test-Path $out) { "built $out ({0} KB)" -f [math]::Round((Get-Item $out).Length / 1KB) }
else { throw 'build failed' }
