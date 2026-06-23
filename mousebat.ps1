param([switch]$Chart)

# Self-contained Logitech mouse battery tray utility. Reads battery from the LGHUB
# agent's local websocket (ws://127.0.0.1:9010 - the same source G HUB's own UI
# uses), draws one numeric tray icon, toasts on full charge / low battery, logs a
# CSV history, and renders a battery chart from it. No LGSTray, no extra runtime:
# compiles to a single ~80 KB windowless exe (ps2exe -noConsole) on top of the
# built-in .NET Framework. A wireless mouse only reports battery while awake, so
# the last reading is cached to disk and shown when the mouse is asleep/off.

$ErrorActionPreference = 'Stop'
$env:LIB = ""; $env:LIBPATH = ""; $env:INCLUDE = ""   # ignore leaked VS toolchain vars (break Add-Type)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Dir       = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
$script:Logo      = Join-Path $script:Dir 'applogo.png'
$script:LogFile   = Join-Path $script:Dir 'mousebat.log'
$script:DataFile  = Join-Path $script:Dir 'battery-history.csv'
$script:StateFile = Join-Path $script:Dir 'battery-state.json'
$script:ChartFile = Join-Path $script:Dir 'battery-chart.png'
$script:FullMin   = 95.0
$script:LowThresh = 5.0
$script:LowRearm  = 10.0
$script:Icons     = @{}   # name -> @{ Ni; Handle; IconObj }
$script:Prev      = @{}   # name -> previous charging (full falling-edge)
$script:LowSt     = @{}   # name -> low toast fired this drain cycle
$script:LastRow   = @{}   # name -> last CSV "pct|charging"
$script:SrvUp     = $null

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
        [void]$menu.Items.Add('Battery chart', $null, { Invoke-Chart; try { Start-Process $script:ChartFile } catch { } })
        [void]$menu.Items.Add('Exit', $null, { Stop-App })
        $ni.ContextMenuStrip = $menu; $ni.Visible = $true
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
        $res = Get-GHubMice
        if (-not $res.Reachable) {
            if ($script:SrvUp -ne $false) { Write-Log 'LGHUB agent unreachable'; $script:SrvUp = $false }
        } else {
            if ($script:SrvUp -ne $true) { Write-Log 'LGHUB agent up'; $script:SrvUp = $true }
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

Write-Log "mousebat starting (GHub ws, toast=$($script:HasToast))"
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
