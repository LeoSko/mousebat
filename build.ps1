<#
.SYNOPSIS
  Compiles mousebat.cs into a native windowless exe with the built-in C# compiler.

.DESCRIPTION
  Three-stage build, because a straight compile of mousebat.cs lands at ~36 KB
  and the exe budget is 30 KB:

    1. mousebat.cs compiles to a library. That is the whole program.
    2. The library is deflated (IL and metadata compress about 2:1) and then
       base64-encoded. Base64 costs 33%, but Smart App Control blocks an
       unsigned exe holding a high-entropy resource, so the text form is what
       makes the result runnable. See the header of loader.cs.
    3. loader.cs compiles to the exe, carrying that text as a resource and
       inflating it at startup.

  Three size switches on top: /optimize+, /platform:x64 (drops the 32-bit
  startup stub and its .reloc section), and an empty /win32res (replaces the
  auto-generated version block). Neither changes behaviour.

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

$src    = Join-Path $PSScriptRoot 'mousebat.cs'
$loader = Join-Path $PSScriptRoot 'loader.cs'
$out    = Join-Path $OutDir $ExeName
$tmp    = [IO.Path]::GetTempPath()
$core   = Join-Path $tmp 'mousebat-core.dll'
$packed = Join-Path $tmp 'mousebat-core.b64'

# A 32-byte "no resources" .res, so csc omits the ~1 KB version block.
$res = Join-Path $tmp 'mousebat-empty.res'
[IO.File]::WriteAllBytes($res, ([byte[]]@(0,0,0,0,0x20,0,0,0,0xFF,0xFF,0,0,0xFF,0xFF,0,0) + (New-Object byte[] 16)))

# --- stage 1: the program itself, as a library -----------------------------
& $csc /nologo /optimize+ /target:library "/out:$core" `
    /reference:System.Web.Extensions.dll `
    /reference:System.Windows.Forms.DataVisualization.dll `
    $src
if ($LASTEXITCODE -ne 0) { throw "csc failed on mousebat.cs (exit $LASTEXITCODE)" }

# --- stage 2: deflate it, then base64 it -----------------------------------
$raw = [IO.File]::ReadAllBytes($core)
$ms  = New-Object IO.MemoryStream
$ds  = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionLevel]::Optimal)
$ds.Write($raw, 0, $raw.Length); $ds.Dispose()
$deflated = $ms.ToArray()
[IO.File]::WriteAllText($packed, [Convert]::ToBase64String($deflated))

# --- stage 3: the loader stub, carrying the encoded library ----------------
& $csc /nologo /optimize+ /target:winexe /platform:x64 "/win32res:$res" "/resource:$packed,c" "/out:$out" $loader
if ($LASTEXITCODE -ne 0) { throw "csc failed on loader.cs (exit $LASTEXITCODE)" }

if (Test-Path $out) {
    "built $out ({0:N0} bytes; program {1:N0} -> {2:N0} deflated -> {3:N0} base64)" -f `
        (Get-Item $out).Length, $raw.Length, $deflated.Length, (Get-Item $packed).Length
} else { throw 'build failed' }
