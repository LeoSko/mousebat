param(
    [int]$PollSeconds = 60,     # how often to poll the local LGSTray HTTP server
    [double]$FullMin  = 95.0,   # charge-stop at/above this % counts as "full"
    [double]$LowThresh = 5.0,   # warn when battery drops below this %
    [double]$LowRearm  = 10.0   # re-arm the low warning once back above this %
)

# Headless battery notifier for wireless Logitech mice. LGSTray already draws its
# own tray icon per device (and can't be told to hide it), so this runs with NO
# icon of its own to avoid a duplicate. It only adds what LGSTray lacks:
#   - toasts on full charge and on low battery, and
#   - a CSV discharge log (battery-history.csv) for discharge-stats.ps1.
# Mice are auto-discovered from LGSTray's local HTTP server (no hardcoded id).

$ErrorActionPreference = 'Stop'

# Our own folder whether running as a .ps1 ($PSScriptRoot) or a compiled exe (no $PSScriptRoot).
$script:Dir      = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
$script:Base     = 'http://localhost:12321'
$script:Logo     = Join-Path $script:Dir 'applogo.png'
$script:LogFile  = Join-Path $script:Dir 'charge-notify.log'
$script:DataFile = Join-Path $script:Dir 'battery-history.csv'   # discharge stats source (one row per state change)
$script:Prev     = @{}   # name -> tri-state previous 'charging' (for full falling-edge)
$script:LowSt    = @{}   # name -> bool (low toast already fired this drain cycle)
$script:LastRow  = @{}   # name -> last logged "pct|charging" (CSV row written only on change)
$script:SrvUp    = $null # tri-state reachability of the LGSTray server (edge-logged, not per-poll)

# Never let a BurntToast import problem kill the watcher — it must keep logging.
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

# Append one CSV row per mouse, but only when % or charging changed since the last
# row (a flat sleep period is then two timestamps: entry + exit, which is all the
# discharge-rate analysis needs). ISO-8601 timestamps so the stats script can parse.
function Write-Data($mouse) {
    $key = "$($mouse.Percent)|$($mouse.Charging)"
    if ($script:LastRow[$mouse.Name] -eq $key) { return }
    $script:LastRow[$mouse.Name] = $key
    try {
        if (-not (Test-Path $script:DataFile)) {
            Add-Content -Path $script:DataFile -Value 'timestamp,name,percent,charging,voltage'
        }
        $row = '{0},{1},{2},{3},{4}' -f (Get-Date -Format 'o'), ($mouse.Name -replace ',', ' '), $mouse.Percent, $mouse.Charging, $mouse.Voltage
        Add-Content -Path $script:DataFile -Value $row
    } catch { Write-Log "data write failed: $_" }
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

function Invoke-Poll {
    try {
        $mice = Get-LgsMice
        if ($null -eq $mice) {
            # Edge-log the DOWN transition only (not every poll) and point at the
            # crash cause: LGSTray writes crashlog_<unixtime>.log with a stack trace.
            if ($script:SrvUp -ne $false) {
                $cl = Get-ChildItem (Join-Path $script:Dir 'crashlog_*.log') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                $note = if ($cl) { " (LGSTray exited; newest crashlog: $($cl.Name) @ $($cl.LastWriteTime.ToString('HH:mm:ss')))" } else { ' (LGSTray not responding; no crashlog found)' }
                Write-Log "LGSTray server DOWN$note"
                $script:SrvUp = $false
            }
            return
        }
        if ($script:SrvUp -ne $true) { Write-Log 'LGSTray server up'; $script:SrvUp = $true }

        foreach ($m in $mice) {
            # LGSTray reports a negative percent until it has a fresh reading.
            if ($m.Percent -lt 0) { continue }   # no reading yet: don't alert, don't move the charging edge
            Write-Data $m

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
    } catch { Write-Log "poll failed: $_" }
}

# --- run --------------------------------------------------------------------
Write-Log "watcher starting (headless, poll ${PollSeconds}s, toast=$($script:HasToast))"

# "Armed" toast once per machine only (marker file), so relaunches stay silent.
$armedFlag = Join-Path $script:Dir '.armed'
if (-not (Test-Path $armedFlag)) {
    Show-Toast 'Mouse battery watcher armed' ("Pings on full charge and below {0}%." -f $LowThresh) 'lg-armed'
    try { New-Item -ItemType File -Path $armedFlag -Force | Out-Null } catch { }
}

# Top-level guard: log why the watcher died before exiting (no auto-restart by
# design — a clean crash trail in charge-notify.log is enough to debug the cause).
try {
    Invoke-Poll
    while ($true) { Start-Sleep -Seconds $PollSeconds; Invoke-Poll }
} catch {
    Write-Log "FATAL watcher exit: $($_.Exception.Message)"
    throw
}
