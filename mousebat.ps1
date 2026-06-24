param([switch]$Chart)

# Self-contained Logitech mouse battery tray utility. Reads battery directly over
# HID++ from the receiver (works with G HUB closed), and falls back to the LGHUB
# agent's local websocket (ws://127.0.0.1:9010) if HID++ returns nothing while
# G HUB is up. Draws one numeric tray icon, toasts on full charge / low battery,
# logs a CSV history, and renders a battery chart from it. No LGSTray, no extra
# runtime: compiles to a single ~80 KB windowless exe (ps2exe -noConsole) on the
# built-in .NET Framework. A wireless mouse only reports battery while awake, so
# the last reading is cached to disk and shown when the mouse is asleep/off.

$ErrorActionPreference = 'Stop'
$env:LIB = ""; $env:LIBPATH = ""; $env:INCLUDE = ""   # ignore leaked VS toolchain vars (break Add-Type)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Win32 HID for the direct HID++ reader (works with G HUB off; the only reader
# that does). Reads through the receiver's long-report interface (UsagePage
# 0xFF00, 20-byte reports) with overlapped I/O + timeouts.
if (-not ('Hid.Api' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Hid {
  [StructLayout(LayoutKind.Sequential)] public struct HIDD_ATTRIBUTES { public int Size; public ushort VendorID; public ushort ProductID; public ushort VersionNumber; }
  [StructLayout(LayoutKind.Sequential)] public struct HIDP_CAPS {
    public ushort Usage; public ushort UsagePage; public ushort InputReportByteLength; public ushort OutputReportByteLength; public ushort FeatureReportByteLength;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst=17)] public ushort[] Reserved;
    public ushort NumberLinkCollectionNodes; public ushort a1,a2,a3,a4,a5,a6,a7,a8,a9;
  }
  [StructLayout(LayoutKind.Sequential)] public struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid g; public int Flags; public IntPtr Reserved; }
  [StructLayout(LayoutKind.Sequential)] public struct OVERLAPPED { public IntPtr Internal; public IntPtr InternalHigh; public uint OffLow; public uint OffHigh; public IntPtr hEvent; }
  public static class Api {
    [DllImport("hid.dll")] public static extern void HidD_GetHidGuid(out Guid g);
    [DllImport("hid.dll")] public static extern bool HidD_GetAttributes(IntPtr h, ref HIDD_ATTRIBUTES a);
    [DllImport("hid.dll")] public static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr pp);
    [DllImport("hid.dll")] public static extern bool HidD_FreePreparsedData(IntPtr pp);
    [DllImport("hid.dll")] public static extern int  HidP_GetCaps(IntPtr pp, out HIDP_CAPS caps);
    [DllImport("setupapi.dll", CharSet=CharSet.Auto)] public static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr w, int f);
    [DllImport("setupapi.dll")] public static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr d, ref Guid g, int i, ref SP_DEVICE_INTERFACE_DATA data);
    [DllImport("setupapi.dll", CharSet=CharSet.Auto)] public static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr s, ref SP_DEVICE_INTERFACE_DATA data, IntPtr det, int sz, ref int req, IntPtr di);
    [DllImport("setupapi.dll")] public static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);
    [DllImport("kernel32.dll", CharSet=CharSet.Auto, SetLastError=true)] public static extern IntPtr CreateFile(string n, uint a, uint sh, IntPtr se, uint dp, uint fl, IntPtr t);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteFile(IntPtr h, byte[] b, int n, out int w, ref OVERLAPPED o);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool ReadFile(IntPtr h, byte[] b, int n, out int r, ref OVERLAPPED o);
    [DllImport("kernel32.dll")] public static extern IntPtr CreateEvent(IntPtr a, bool m, bool i, string n);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] public static extern bool GetOverlappedResult(IntPtr h, ref OVERLAPPED o, out int n, bool wait);
    [DllImport("kernel32.dll")] public static extern bool CancelIo(IntPtr h);
    const uint GENR=0x80000000, GENW=0x40000000, SHARE=3, OPEN=3, OVL=0x40000000; const int PRESENT=0x2, IFACE=0x10;
    public static string FindLongHidpp() {
      Guid g; HidD_GetHidGuid(out g);
      IntPtr set = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, PRESENT|IFACE);
      try {
        for (int i=0;;i++) {
          var d = new SP_DEVICE_INTERFACE_DATA(); d.cbSize = Marshal.SizeOf(d);
          if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref d)) break;
          int req=0; SetupDiGetDeviceInterfaceDetail(set, ref d, IntPtr.Zero, 0, ref req, IntPtr.Zero);
          IntPtr det = Marshal.AllocHGlobal(req); Marshal.WriteInt32(det, IntPtr.Size==8?8:6);
          string path=null;
          if (SetupDiGetDeviceInterfaceDetail(set, ref d, det, req, ref req, IntPtr.Zero)) path = Marshal.PtrToStringAuto(new IntPtr(det.ToInt64()+4));
          Marshal.FreeHGlobal(det);
          if (path==null) continue;
          IntPtr h = CreateFile(path, GENR|GENW, SHARE, IntPtr.Zero, OPEN, 0, IntPtr.Zero);
          if (h==(IntPtr)(-1)) continue;
          try {
            var a = new HIDD_ATTRIBUTES(); a.Size = Marshal.SizeOf(a);
            if (!HidD_GetAttributes(h, ref a) || a.VendorID!=0x046D) continue;
            IntPtr pp; if (!HidD_GetPreparsedData(h, out pp)) continue;
            HIDP_CAPS c; HidP_GetCaps(pp, out c); HidD_FreePreparsedData(pp);
            if (c.UsagePage==0xFF00 && c.OutputReportByteLength==20) return path;
          } finally { CloseHandle(h); }
        }
      } finally { SetupDiDestroyDeviceInfoList(set); }
      return null;
    }
    public static IntPtr Open(string path) { return CreateFile(path, GENR|GENW, SHARE, IntPtr.Zero, OPEN, OVL, IntPtr.Zero); }
    public static bool Write(IntPtr h, byte[] data) {
      var o = new OVERLAPPED(); o.hEvent = CreateEvent(IntPtr.Zero, true, false, null);
      int w; bool ok = WriteFile(h, data, data.Length, out w, ref o);
      if (!ok && Marshal.GetLastWin32Error()==997) { WaitForSingleObject(o.hEvent, 1000); ok = GetOverlappedResult(h, ref o, out w, false); }
      CloseHandle(o.hEvent); return ok;
    }
    public static byte[] Read(IntPtr h, uint timeoutMs) {
      var o = new OVERLAPPED(); o.hEvent = CreateEvent(IntPtr.Zero, true, false, null);
      byte[] buf = new byte[20]; int r; bool ok = ReadFile(h, buf, 20, out r, ref o);
      if (!ok) {
        if (Marshal.GetLastWin32Error()==997) {
          if (WaitForSingleObject(o.hEvent, timeoutMs)==0) ok = GetOverlappedResult(h, ref o, out r, false);
          else { CancelIo(h); CloseHandle(o.hEvent); return null; }
        } else { CloseHandle(o.hEvent); return null; }
      }
      CloseHandle(o.hEvent);
      if (!ok) return null;
      byte[] res = new byte[r]; Array.Copy(buf, res, r); return res;
    }
  }
}
'@
}

$script:Dir       = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
$script:Logo      = Join-Path $script:Dir 'applogo.png'
$script:LogFile   = Join-Path $script:Dir 'mousebat.log'
$script:DataFile  = Join-Path $script:Dir 'battery-history.csv'
$script:StateFile = Join-Path $script:Dir 'battery-state.json'
$script:ChartFile = Join-Path $script:Dir 'battery-chart.png'
$script:SettingsFile = Join-Path $script:Dir 'mousebat-settings.json'
$script:FullMin   = 95.0
$script:LowThresh = 5.0
$script:LowRearm  = 10.0
$script:Icons     = @{}   # name -> @{ Ni; Handle; IconObj }
$script:Prev      = @{}   # name -> previous charging (full falling-edge)
$script:LowSt     = @{}   # name -> low toast fired this drain cycle
$script:LastRow   = @{}   # name -> last CSV "pct|charging"
$script:SrvUp     = $null
$script:GHubName  = $null  # friendly mouse name learned from G HUB (used to label HID++ readings)

try { Import-Module BurntToast -ErrorAction Stop; $script:HasToast = $true } catch { $script:HasToast = $false }

function Write-Log([string]$m) {
    try { Add-Content -Path $script:LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) } catch { }
}
function Show-Toast([string]$title, [string]$text, [string]$id) {
    if (-not $script:HasToast) { return }
    try {
        if (Test-Path $script:Logo) { New-BurntToastNotification -Text $title, $text -AppLogo $script:Logo -UniqueIdentifier $id | Out-Null }
        else                        { New-BurntToastNotification -Text $title, $text -UniqueIdentifier $id | Out-Null }
    } catch { Write-Log "toast failed: $_" }
}
function Write-Data($name, [int]$pct, [bool]$charging) {
    $key = "$pct|$charging"
    if ($script:LastRow[$name] -eq $key) { return }
    $script:LastRow[$name] = $key
    try {
        if (-not (Test-Path $script:DataFile)) { Add-Content -Path $script:DataFile -Value 'timestamp,name,percent,charging' }
        Add-Content -Path $script:DataFile -Value ('{0},{1},{2},{3}' -f (Get-Date -Format 'o'), ($name -replace ',', ' '), $pct, $charging)
    } catch { Write-Log "data write failed: $_" }
}

# --- direct HID++ reader (no G HUB needed) ---------------------------------
# Feature 0x1001 reports voltage only; LGSTray/Solaar mV->% lookup converts it.
$script:MvLUT = 4186,4156,4143,4133,4122,4113,4103,4094,4086,4075,4067,4059,4051,4043,4035,4027,4019,4011,4003,3997,
                3989,3983,3976,3969,3961,3955,3949,3942,3935,3929,3922,3916,3909,3902,3896,3890,3883,3877,3870,3865,
                3859,3853,3848,3842,3837,3833,3828,3824,3819,3815,3811,3808,3804,3800,3797,3793,3790,3787,3784,3781,
                3778,3775,3772,3770,3767,3764,3762,3759,3757,3754,3751,3748,3744,3741,3737,3734,3730,3726,3724,3720,
                3717,3714,3710,3706,3702,3697,3693,3688,3683,3677,3671,3666,3662,3658,3654,3646,3633,3612,3579,3537
$script:SW = 0   # rotating HID++ software id (1..15) so each call matches only its reply

function ConvertTo-Percent([int]$mv) {
    for ($i = 0; $i -lt $script:MvLUT.Length; $i++) { if ($mv -gt $script:MvLUT[$i]) { return $script:MvLUT.Length - $i } }
    return 0
}
function Invoke-Hidpp($h, [byte]$dev, [byte]$feat, [byte]$func, [byte[]]$params) {
    $script:SW = ($script:SW % 15) + 1
    $sw = [byte]$script:SW
    while ($null -ne [Hid.Api]::Read($h, 0)) { }   # flush stale/unsolicited reports
    $req = New-Object byte[] 20
    $req[0] = 0x11; $req[1] = $dev; $req[2] = $feat; $req[3] = ([byte](($func -shl 4) -bor $sw))
    for ($i = 0; $i -lt $params.Length -and $i -lt 16; $i++) { $req[4 + $i] = $params[$i] }
    if (-not [Hid.Api]::Write($h, $req)) { return $null }
    for ($try = 0; $try -lt 16; $try++) {
        $r = [Hid.Api]::Read($h, 500)
        if ($null -eq $r) { return $null }
        if ($r.Length -lt 5 -or $r[1] -ne $dev) { continue }
        if ($r[2] -eq 0xFF -and $r[3] -eq $feat -and ($r[4] -band 0x0F) -eq $sw) { return @{ Error = $r[5] } }
        if ($r[2] -eq $feat -and ($r[3] -band 0x0F) -eq $sw) { return @{ Data = $r } }
    }
    return $null
}
function Get-FeatureIndex($h, [byte]$dev, [int]$fid) {
    $res = Invoke-Hidpp $h $dev 0x00 0x00 @([byte](($fid -shr 8) -band 0xFF), [byte]($fid -band 0xFF))
    if ($res -and $res.Data) { return $res.Data[4] }
    return 0
}
# Returns @{ Percent; Charging } for the first responding mouse, or $null if no
# device answers (asleep / off / receiver unplugged).
function Get-HidppBattery {
    $path = try { [Hid.Api]::FindLongHidpp() } catch { $null }
    if (-not $path) { return $null }
    $h = [Hid.Api]::Open($path)
    if ($h -eq [IntPtr](-1)) { return $null }
    try {
        foreach ($dev in 1, 2, 0xFF) {
            $i1001 = Get-FeatureIndex $h $dev 0x1001
            if (-not $i1001) { continue }
            $r = Invoke-Hidpp $h $dev $i1001 0x00 @()
            if (-not $r -or -not $r.Data) { continue }
            $mv = ([int]$r.Data[4] -shl 8) -bor [int]$r.Data[5]   # [int] cast: PS -shl on [byte] truncates
            if ($mv -lt 2000) { continue }   # implausible (stale/zero) - treat as no reading
            $flags = [int]$r.Data[6]
            $charging = (($flags -band 0x80) -ne 0) -and (($flags -band 0x07) -in 0, 1)   # bit7 set + mode charging/full
            return @{ Percent = ConvertTo-Percent $mv; Charging = $charging }
        }
        return $null
    } finally { [void][Hid.Api]::CloseHandle($h) }
}

# --- reader dispatcher: HID++ first (independent), G HUB websocket fallback --
function Get-Readings {
    $hid = try { Get-HidppBattery } catch { $null }
    if ($hid) {
        $names = @((Get-State).Keys)
        $n = if ($script:GHubName) { $script:GHubName } elseif ($names.Count -eq 1) { $names[0] } else { 'Logitech Mouse' }
        return @{ Reachable = $true; Source = 'hidpp'; Mice = @(@{ Name = $n; Percent = $hid.Percent; Charging = $hid.Charging }) }
    }
    $g = Get-GHubMice
    foreach ($m in $g.Mice) { $script:GHubName = $m.Name }   # remember the friendly name for HID++ labelling
    return @{ Reachable = $g.Reachable; Source = 'ghub'; Mice = $g.Mice }
}

# --- G HUB websocket reader ------------------------------------------------
# Returns @{ Reachable = $bool; Mice = @(@{Name;Percent;Charging}) }. The agent
# closes the socket after ~1s (normal); we connect fresh each poll, query, and
# collect whatever battery states come back before it drops.
function Get-GHubMice {
    $CT = [Threading.CancellationToken]::None
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.AddSubProtocol('json')
    $ws.Options.SetRequestHeader('Origin', 'file://')
    $send = {
        param($json)
        try { $b = [Text.Encoding]::UTF8.GetBytes($json); $ws.SendAsync([System.ArraySegment[byte]]::new($b), 'Text', $true, $CT).Wait(2000) | Out-Null; $true } catch { $false }
    }
    $recv = {
        param($ms)
        try {
            $buf = New-Object byte[] 32768; $seg = [System.ArraySegment[byte]]::new($buf); $sb = New-Object Text.StringBuilder
            do {
                $t = $ws.ReceiveAsync($seg, $CT)
                if (-not $t.Wait($ms)) { return $null }
                $r = $t.Result; [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $r.Count))
            } while (-not $r.EndOfMessage)
            $sb.ToString()
        } catch { '<<closed>>' }
    }
    try {
        try { if (-not $ws.ConnectAsync([Uri]'ws://127.0.0.1:9010', $CT).Wait(3000)) { return @{ Reachable = $false; Mice = @() } } }
        catch { return @{ Reachable = $false; Mice = @() } }
        if ($ws.State -ne 'Open') { return @{ Reachable = $false; Mice = @() } }

        & $send '{"msgId":"","verb":"GET","path":"/devices/list"}' | Out-Null
        $devs = $null
        for ($i = 0; $i -lt 12 -and $null -eq $devs; $i++) {
            $m = & $recv 1500; if (-not $m -or $m -eq '<<closed>>') { break }
            $o = try { $m | ConvertFrom-Json } catch { $null }
            if ($o -and $o.path -eq '/devices/list') { $devs = $o.payload.deviceInfos }
        }
        if (-not $devs) { return @{ Reachable = $true; Mice = @() } }

        $want = @{}
        foreach ($d in $devs) {
            if ($d.capabilities.hasBatteryStatus -and "$($d.deviceType)" -match 'MOUSE') {
                $want[$d.id] = $d.extendedDisplayName
                & $send ('{{"msgId":"","verb":"GET","path":"/battery/{0}/state"}}' -f $d.id) | Out-Null
            }
        }
        $mice = @(); $seen = @{}
        for ($i = 0; $i -lt 24 -and $seen.Count -lt $want.Count; $i++) {
            $m = & $recv 1500; if (-not $m -or $m -eq '<<closed>>') { break }
            $o = try { $m | ConvertFrom-Json } catch { $null }
            if ($o -and $o.path -like '/battery/*' -and $o.payload.deviceId) {
                $id = "$($o.payload.deviceId)"
                if ($want.ContainsKey($id) -and -not $seen.ContainsKey($id) -and $null -ne $o.payload.percentage) {
                    $seen[$id] = $true
                    $mice += @{ Name = "$($want[$id])"; Percent = [int]$o.payload.percentage; Charging = [bool]$o.payload.charging }
                }
            }
        }
        return @{ Reachable = $true; Mice = $mice }
    } finally { try { $ws.Dispose() } catch { } }
}

# --- last-known state cache (so the icon shows a value while the mouse sleeps) --
function Get-State {
    if (-not (Test-Path $script:StateFile)) { return @{} }
    try {
        $h = @{}
        (Get-Content $script:StateFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
            $h[$_.Name] = @{ Percent = [int]$_.Value.Percent; Charging = [bool]$_.Value.Charging }
        }
        return $h
    } catch { return @{} }
}
function Save-State($state) {
    try { $state | ConvertTo-Json -Depth 4 | Set-Content -Path $script:StateFile } catch { Write-Log "state save failed: $_" }
}

# --- notification thresholds (editable from the tray, persisted to JSON) -----
function Get-Settings {
    if (-not (Test-Path $script:SettingsFile)) { return }
    try {
        $s = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
        if ($null -ne $s.FullMin)   { $script:FullMin   = [double]$s.FullMin }
        if ($null -ne $s.LowThresh) { $script:LowThresh = [double]$s.LowThresh }
        if ($null -ne $s.LowRearm)  { $script:LowRearm  = [double]$s.LowRearm }
    } catch { Write-Log "settings load failed: $_" }
}
function Save-Settings {
    try { [pscustomobject]@{ FullMin = $script:FullMin; LowThresh = $script:LowThresh; LowRearm = $script:LowRearm } | ConvertTo-Json | Set-Content -Path $script:SettingsFile }
    catch { Write-Log "settings save failed: $_" }
}
function Show-Settings {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Mouse Battery - notification thresholds'
    $f.ClientSize = New-Object System.Drawing.Size(310, 170)
    $f.FormBorderStyle = 'FixedDialog'; $f.StartPosition = 'CenterScreen'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.TopMost = $true
    $mk = {
        param([string]$text, [int]$y, [int]$min, [int]$max, $val)
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $text; $lbl.SetBounds(14, ($y + 3), 220, 20); $f.Controls.Add($lbl)
        $nud = New-Object System.Windows.Forms.NumericUpDown
        $nud.SetBounds(236, $y, 60, 24); $nud.Minimum = $min; $nud.Maximum = $max; $nud.DecimalPlaces = 0
        $nud.Value = [decimal][math]::Min([math]::Max($val, $min), $max); $f.Controls.Add($nud); $nud
    }
    $nLow  = & $mk 'Low battery warning at (%):' 20  1 50  ([int]$script:LowThresh)
    $nRe   = & $mk 'Re-arm low warning above (%):' 52 1 60 ([int]$script:LowRearm)
    $nFull = & $mk 'Full charge at (%):' 84 50 100 ([int]$script:FullMin)
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Save'; $ok.SetBounds(135, 128, 75, 28); $ok.DialogResult = 'OK'; $f.Controls.Add($ok); $f.AcceptButton = $ok
    $cn = New-Object System.Windows.Forms.Button; $cn.Text = 'Cancel'; $cn.SetBounds(218, 128, 75, 28); $cn.DialogResult = 'Cancel'; $f.Controls.Add($cn); $f.CancelButton = $cn
    if ($f.ShowDialog() -eq 'OK') {
        $script:LowThresh = [double]$nLow.Value
        $script:LowRearm  = [double]$nRe.Value
        $script:FullMin   = [double]$nFull.Value
        Save-Settings
        Write-Log "settings updated: low=$($script:LowThresh) rearm=$($script:LowRearm) full=$($script:FullMin)"
    }
    $f.Dispose()
}

# --- tray icon -------------------------------------------------------------
function New-PercentIcon([object]$pct, [string]$status) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)
    if     ($status -eq 'unknown')  { $col = [System.Drawing.Color]::FromArgb(127, 140, 141) }
    elseif ($status -eq 'full')     { $col = [System.Drawing.Color]::FromArgb(39, 174, 96) }
    elseif ($status -eq 'charging') { $col = [System.Drawing.Color]::FromArgb(41, 128, 185) }
    elseif ($pct -ge 60)            { $col = [System.Drawing.Color]::FromArgb(46, 204, 113) }
    elseif ($pct -ge 30)            { $col = [System.Drawing.Color]::FromArgb(243, 156, 18) }
    else                            { $col = [System.Drawing.Color]::FromArgb(231, 76, 60) }
    $brush = New-Object System.Drawing.SolidBrush $col
    $g.FillEllipse($brush, 0, 0, 31, 31)
    $label = if ($status -eq 'unknown') { '?' } elseif ([int]$pct -ge 100) { 'F' } else { "$([int]$pct)" }
    $fpx = if ($label.Length -ge 3) { 13 } elseif ($label.Length -eq 2) { 17 } else { 21 }
    $font = New-Object System.Drawing.Font('Segoe UI', $fpx, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $g.DrawString($label, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 0, 32, 32)), $sf)
    $g.Dispose(); $brush.Dispose(); $font.Dispose(); $sf.Dispose()
    $hicon = $bmp.GetHicon(); $icon = [System.Drawing.Icon]::FromHandle($hicon); $bmp.Dispose()
    [pscustomobject]@{ Icon = $icon; Handle = $hicon }
}
if (-not ('Win32.IconUtil' -as [type])) {
    Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);' -Name IconUtil -Namespace Win32 | Out-Null
}
function Remove-MouseIcon([string]$name) {
    $slot = $script:Icons[$name]; if (-not $slot) { return }
    $slot.Ni.Visible = $false
    if ($slot.IconObj) { $slot.IconObj.Dispose() }
    if ($slot.Handle -and $slot.Handle -ne [IntPtr]::Zero) { [void][Win32.IconUtil]::DestroyIcon($slot.Handle) }
    $slot.Ni.Dispose(); $script:Icons.Remove($name)
}
function Stop-App {
    if ($script:Timer) { $script:Timer.Stop() }
    foreach ($n in @($script:Icons.Keys)) { Remove-MouseIcon $n }
    if ($script:Ctx) { $script:Ctx.ExitThread() }
}
function Update-MouseIcon([string]$name, [int]$pct, [string]$status, [bool]$stale) {
    if (-not $script:Icons.ContainsKey($name)) {
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        [void]$menu.Items.Add('Settings...', $null, { Show-Settings })
        [void]$menu.Items.Add('Battery chart', $null, { Invoke-Chart; try { Start-Process $script:ChartFile } catch { } })
        [void]$menu.Items.Add('Exit', $null, { Stop-App })
        $ni.ContextMenuStrip = $menu; $ni.Visible = $true
        $ni.add_DoubleClick({ Show-Settings })   # double-click the tray icon edits thresholds
        $script:Icons[$name] = @{ Ni = $ni; Handle = [IntPtr]::Zero; IconObj = $null }
    }
    $slot = $script:Icons[$name]
    $new = New-PercentIcon $pct $status
    $slot.Ni.Icon = $new.Icon
    if ($slot.IconObj) { $slot.IconObj.Dispose() }
    if ($slot.Handle -and $slot.Handle -ne [IntPtr]::Zero) { [void][Win32.IconUtil]::DestroyIcon($slot.Handle) }
    $slot.IconObj = $new.Icon; $slot.Handle = $new.Handle
    $tip = "$name - $pct% ($status)$(if ($stale) { ' - last known' })"
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    $slot.Ni.Text = $tip
}

# --- chart -----------------------------------------------------------------
function Invoke-Chart {
    if (-not (Test-Path $script:DataFile)) { Write-Log 'chart: no history yet'; return }
    try {
        Add-Type -AssemblyName System.Windows.Forms.DataVisualization
        $rows = Import-Csv $script:DataFile
        $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
        $chart.Width = 1000; $chart.Height = 420; $chart.BackColor = [System.Drawing.Color]::White
        $area = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
        $area.AxisX.Title = 'Time'; $area.AxisY.Title = 'Battery %'; $area.AxisY.Minimum = 0; $area.AxisY.Maximum = 100
        $area.AxisX.LabelStyle.Format = 'MM-dd HH:mm'; $area.AxisX.MajorGrid.LineColor = [System.Drawing.Color]::Gainsboro; $area.AxisY.MajorGrid.LineColor = [System.Drawing.Color]::Gainsboro
        $chart.ChartAreas.Add($area)
        $title = $chart.Titles.Add('Mouse battery history')
        $title.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
        foreach ($grp in ($rows | Group-Object name)) {
            $s = New-Object System.Windows.Forms.DataVisualization.Charting.Series
            $s.Name = $grp.Name; $s.ChartType = 'Line'; $s.BorderWidth = 2; $s.XValueType = 'DateTime'
            foreach ($r in $grp.Group) { [void]$s.Points.AddXY([datetime]::Parse($r.timestamp), [int]$r.percent) }
            $chart.Series.Add($s)
        }
        $chart.Legends.Add((New-Object System.Windows.Forms.DataVisualization.Charting.Legend)) | Out-Null
        $chart.SaveImage($script:ChartFile, 'Png')
        Write-Log "chart written: $script:ChartFile"
    } catch { Write-Log "chart failed: $_" }
}

# --- poll ------------------------------------------------------------------
function Invoke-Poll {
    try {
        $res = Get-Readings
        if (-not $res.Reachable) {
            if ($script:SrvUp -ne $false) { Write-Log 'no battery source (mouse off HID++ and G HUB down)'; $script:SrvUp = $false }
        } elseif ($res.Mice.Count) {
            if ($script:SrvUp -ne $true) { Write-Log "battery source up ($($res.Source))"; $script:SrvUp = $true }
        }

        $state = Get-State
        foreach ($m in $res.Mice) {
            $name = $m.Name; $pct = $m.Percent; $charging = $m.Charging
            $state[$name] = @{ Percent = $pct; Charging = $charging }
            Write-Data $name $pct $charging
            $status = if ($charging) { if ($pct -ge $script:FullMin) { 'full' } else { 'charging' } } else { 'discharging' }
            Update-MouseIcon $name $pct $status $false

            if ($script:Prev[$name] -eq $true -and -not $charging -and $pct -ge $script:FullMin) {
                Show-Toast "$name fully charged" ("{0} at {1}% - unplug it." -f $name, $pct) "lg-full-$name"
            }
            if (-not $charging -and $pct -lt $script:LowThresh -and -not $script:LowSt[$name]) {
                Show-Toast "$name battery low" ("{0} at {1}% - charge it." -f $name, $pct) "lg-low-$name"
                $script:LowSt[$name] = $true
            }
            if ($charging -or $pct -ge $script:LowRearm) { $script:LowSt[$name] = $false }
            $script:Prev[$name] = $charging
        }
        # mice with no fresh reading this cycle: show cached value (marked stale)
        $fresh = @{}; $res.Mice | ForEach-Object { $fresh[$_.Name] = $true }
        foreach ($name in @($state.Keys)) {
            if ($fresh.ContainsKey($name)) { continue }
            $c = $state[$name]
            $status = if ($c.Charging) { if ($c.Percent -ge $script:FullMin) { 'full' } else { 'charging' } } else { 'discharging' }
            Update-MouseIcon $name $c.Percent $status $true
        }
        Save-State $state
    } catch { Write-Log "poll failed: $_" }
}

# --- run -------------------------------------------------------------------
if ($Chart) { Invoke-Chart; if (Test-Path $script:ChartFile) { Start-Process $script:ChartFile }; return }

Write-Log "mousebat starting (HID++ + GHub fallback, toast=$($script:HasToast))"
Get-Settings   # load saved thresholds (overrides the defaults above)
# Seed the cache from the last CSV reading so an icon shows at once (mouse may be asleep at logon).
if (-not (Test-Path $script:StateFile) -and (Test-Path $script:DataFile)) {
    $seed = @{}
    Import-Csv $script:DataFile | ForEach-Object { $seed[$_.name] = @{ Percent = [int]$_.percent; Charging = ($_.charging -eq 'True') } }
    if ($seed.Count) { Save-State $seed }
}
$armed = Join-Path $script:Dir '.armed'
if (-not (Test-Path $armed)) {
    Show-Toast 'Mouse battery watcher armed' ("Pings on full charge and below {0}%." -f $script:LowThresh) 'lg-armed'
    try { New-Item -ItemType File -Path $armed -Force | Out-Null } catch { }
}

$script:Ctx = New-Object System.Windows.Forms.ApplicationContext
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 60000
$script:Timer.add_Tick({ Invoke-Poll })
Invoke-Poll
$script:Timer.Start()
[System.Windows.Forms.Application]::Run($script:Ctx)
