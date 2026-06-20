param(
    [int]$PollSeconds = 60,     # how often to poll the local LGSTray HTTP server
    [double]$FullMin  = 95.0,   # charge-stop at/above this % counts as "full"
    [double]$LowThresh = 5.0,   # warn when battery drops below this %
    [double]$LowRearm  = 10.0   # re-arm the low warning once back above this %
)

# Tray battery monitor for wireless Logitech mice. Auto-discovers the connected
# mouse from LGSTray's local HTTP server (no hardcoded device id), shows one
# tray icon per mouse with its battery % drawn in a level-tracking colour, and
# raises a toast on full charge and on low battery.

$ErrorActionPreference = 'Stop'
$env:LIB = ""; $env:LIBPATH = ""; $env:INCLUDE = ""   # ignore any leaked VS toolchain vars (they break Add-Type's compiler)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Our own folder whether running as a .ps1 ($PSScriptRoot) or a compiled exe (no $PSScriptRoot).
$script:Dir     = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
$script:Base    = 'http://localhost:12321'
$script:Logo    = Join-Path $script:Dir 'applogo.png'
$script:LogFile = Join-Path $script:Dir 'charge-notify.log'
$script:Icons   = @{}   # name -> @{ Ni; Handle; IconObj }
$script:Prev    = @{}   # name -> tri-state previous 'charging' (for full falling-edge)
$script:LowSt   = @{}   # name -> bool (low toast already fired this drain cycle)

# Never let a BurntToast import problem kill the app — the tray icon must still run.
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

# Discover mice from the LGSTray server. Returns one object per physical mouse
# (LGSTray can list the same mouse twice via Native + GHub; dedupe by name,
# preferring the entry with a real voltage and the freshest update).
# Returns $null when the server is unreachable (distinct from "no mice").
function Get-LgsMice {
    try { $root = (Invoke-WebRequest -Uri "$($script:Base)/" -UseBasicParsing -TimeoutSec 5).Content }
    catch { return $null }

    $ids = [regex]::Matches($root, 'href="/device/([^"]+)"') |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -notmatch '%' } | Select-Object -Unique

    $devs = @()
    foreach ($id in $ids) {
        try { $x = ([xml](Invoke-WebRequest -Uri "$($script:Base)/device/$id" -UseBasicParsing -TimeoutSec 5).Content).xml }
        catch { continue }
        if ("$($x.device_type)" -ne 'Mouse') { continue }
        $devs += [pscustomobject]@{
            Id       = "$($x.device_id)"
            Name     = "$($x.device_name)"
            Percent  = [int][math]::Round([double]$x.battery_percent)
            Charging = ("$($x.charging)".Trim().ToLower() -in @('true', 'charging', '1'))
            Voltage  = [double]$x.battery_voltage
            Updated  = try { [datetimeoffset]::Parse($x.last_update) } catch { [datetimeoffset]::MinValue }
        }
    }
    ,@($devs | Group-Object Name | ForEach-Object {
        $_.Group | Sort-Object @{ e = { $_.Voltage -gt 0 }; Descending = $true }, @{ e = { $_.Updated }; Descending = $true } | Select-Object -First 1
    })
}

# Draw a 32x32 tray icon: filled disc coloured by level, battery % in white.
function New-PercentIcon([object]$pct, [string]$status) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
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
    $fpx   = if ($label.Length -ge 3) { 13 } elseif ($label.Length -eq 2) { 17 } else { 21 }
    $font  = New-Object System.Drawing.Font('Segoe UI', $fpx, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $sf    = New-Object System.Drawing.StringFormat
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $g.DrawString($label, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 0, 32, 32)), $sf)

    $g.Dispose(); $brush.Dispose(); $font.Dispose(); $sf.Dispose()
    $hicon = $bmp.GetHicon()
    $icon  = [System.Drawing.Icon]::FromHandle($hicon)
    $bmp.Dispose()
    [pscustomobject]@{ Icon = $icon; Handle = $hicon }
}

# DestroyIcon — GetHicon() leaks a GDI handle on every update without it.
if (-not ('Win32.IconUtil' -as [type])) {
    Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);' -Name IconUtil -Namespace Win32 | Out-Null
}

function Remove-MouseIcon([string]$name) {
    $slot = $script:Icons[$name]
    if (-not $slot) { return }
    $slot.Ni.Visible = $false
    if ($slot.IconObj) { $slot.IconObj.Dispose() }
    if ($slot.Handle -and $slot.Handle -ne [IntPtr]::Zero) { [void][Win32.IconUtil]::DestroyIcon($slot.Handle) }
    $slot.Ni.Dispose()
    $script:Icons.Remove($name)
}

function Stop-App {
    if ($script:Timer) { $script:Timer.Stop() }
    foreach ($n in @($script:Icons.Keys)) { Remove-MouseIcon $n }
    if ($script:Ctx) { $script:Ctx.ExitThread() }
}

function Update-MouseIcon($mouse, [string]$status) {
    $n = $mouse.Name
    if (-not $script:Icons.ContainsKey($n)) {
        $ni   = New-Object System.Windows.Forms.NotifyIcon
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        [void]$menu.Items.Add('Exit', $null, { Stop-App })
        $ni.ContextMenuStrip = $menu
        $ni.Visible = $true
        $script:Icons[$n] = @{ Ni = $ni; Handle = [IntPtr]::Zero; IconObj = $null }
        Write-Log "added icon for $n"
    }
    $slot = $script:Icons[$n]

    $new = New-PercentIcon $mouse.Percent $status
    $slot.Ni.Icon = $new.Icon
    if ($slot.IconObj) { $slot.IconObj.Dispose() }
    if ($slot.Handle -and $slot.Handle -ne [IntPtr]::Zero) { [void][Win32.IconUtil]::DestroyIcon($slot.Handle) }
    $slot.IconObj = $new.Icon
    $slot.Handle  = $new.Handle

    $tip = if ($status -eq 'unknown') { "$n - battery unknown" } else { "$n - $($mouse.Percent)% ($status)" }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    $slot.Ni.Text = $tip
}

function Invoke-Poll {
    try {
        $mice = Get-LgsMice
        if ($null -eq $mice) { Write-Log 'LGSTray server unreachable'; return }   # keep last icons, no toasts

        $present = @{}
        foreach ($m in $mice) {
            $present[$m.Name] = $true
            # LGSTray reports a negative percent until it has a fresh reading.
            $status = if ($m.Percent -lt 0) { 'unknown' }
                      elseif ($m.Charging) { if ($m.Percent -ge $FullMin) { 'full' } else { 'charging' } }
                      else { 'discharging' }
            try { Update-MouseIcon $m $status } catch { Write-Log "icon $($m.Name) failed: $_" }
            if ($m.Percent -lt 0) { continue }   # no reading yet: don't alert, don't move the charging edge

            # Full: falling edge of the charging flag while at/above full (never false-fires
            # at startup — must observe charging=True first).
            if ($script:Prev[$m.Name] -eq $true -and -not $m.Charging -and $m.Percent -ge $FullMin) {
                Show-Toast "$($m.Name) fully charged" ("{0} at {1}% - unplug it." -f $m.Name, $m.Percent) "lg-full-$($m.Name)"
            }
            # Low: below threshold, not charging, once per drain cycle.
            if (-not $m.Charging -and $m.Percent -lt $LowThresh -and -not $script:LowSt[$m.Name]) {
                Show-Toast "$($m.Name) battery low" ("{0} at {1}% - charge it." -f $m.Name, $m.Percent) "lg-low-$($m.Name)"
                $script:LowSt[$m.Name] = $true
            }
            if ($m.Charging -or $m.Percent -ge $LowRearm) { $script:LowSt[$m.Name] = $false }
            $script:Prev[$m.Name] = $m.Charging
        }
        foreach ($n in @($script:Icons.Keys)) {
            if (-not $present.ContainsKey($n)) { Write-Log "removed icon for $n"; Remove-MouseIcon $n }
        }
    } catch { Write-Log "poll failed: $_" }
}

# --- run --------------------------------------------------------------------
Write-Log "watcher starting (poll ${PollSeconds}s, toast=$($script:HasToast))"
$script:Ctx   = New-Object System.Windows.Forms.ApplicationContext
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = $PollSeconds * 1000
$script:Timer.add_Tick({ Invoke-Poll })

Invoke-Poll
Show-Toast 'Mouse battery watcher armed' ("Watching {0} mouse(s); pings on full charge and below {1}%." -f $script:Icons.Count, $LowThresh) 'lg-armed'

$script:Timer.Start()
[System.Windows.Forms.Application]::Run($script:Ctx)
