<#
.SYNOPSIS
  Compiles mousebat.cs into a native windowless exe with the built-in C# compiler.

.DESCRIPTION
  One plain compile, and the exe budget is 50 KB.

  The exe used to ship deflated inside a loader stub to fit a 30 KB budget.
  ESET flagged that shape as Trojan.ML/Augur (a stub that unpacks an encoded
  payload at startup reads as a packer) and deleted the exe. The plain exe
  does not trip it.

  Two size switches: /platform:x64 (drops the 32-bit startup stub and its
  .reloc section) and an empty /win32res (replaces the auto-generated version
  block). Neither changes behaviour.

  Extra references beyond the csc defaults:
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

# A 32-byte "no resources" .res, so csc omits the ~1 KB version block.
$res = Join-Path ([IO.Path]::GetTempPath()) 'mousebat-empty.res'
[IO.File]::WriteAllBytes($res, ([byte[]]@(0,0,0,0,0x20,0,0,0,0xFF,0xFF,0,0,0xFF,0xFF,0,0) + [byte[]]::new(16)))

& $csc /nologo /optimize+ /target:winexe /platform:x64 "/win32res:$res" "/out:$out" `
    /reference:System.Web.Extensions.dll `
    /reference:System.Windows.Forms.DataVisualization.dll `
    $src
if ($LASTEXITCODE -ne 0) { throw "csc failed on mousebat.cs (exit $LASTEXITCODE)" }

if (-not (Test-Path $out)) { throw 'build failed' }
$size = (Get-Item $out).Length
if ($size -gt 50KB) { throw ("exe is {0:N0} bytes, over the 50 KB budget" -f $size) }
"built $out ({0:N0} bytes)" -f $size
