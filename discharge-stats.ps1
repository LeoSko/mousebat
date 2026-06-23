<#
.SYNOPSIS
  Discharge statistics + "is it draining faster than usual?" analysis for the
  Logitech mouse battery, from battery-history.csv (written by mousebat.ps1).

.DESCRIPTION
  The mouse has a sleep mode: idle it drains very slowly, in use much faster, so a
  single %/hr figure is meaningless. Every discharge interval (a gap between two
  consecutive readings while NOT charging and the % dropped) is classified by its
  rate: below -SleepThreshold %/hr is "sleep", above is "active". The anomaly
  verdict compares the ACTIVE drain rate over the recent window against the active
  baseline (everything older) so idle time never skews it.

  Rates are duration-weighted: total % drained / total hours, so brief intervals
  don't dominate. Voltage is ignored (the GHub backend reports it as 0).
#>
param(
    [string]$CsvPath        = (Join-Path $PSScriptRoot 'battery-history.csv'),
    [double]$SleepThreshold = 0.5,   # %/hr below this = sleep/idle, above = active use
    [double]$RecentHours    = 24,    # "recent" window for the anomaly check
    [double]$AnomalyFactor  = 1.4,   # recent/baseline active rate at/above this = "faster than usual"
    [double]$MinActiveHours = 3      # need at least this many active-hours each side for a verdict
)

if (-not (Test-Path $CsvPath)) { Write-Host "No data yet: $CsvPath not found. Let the watcher run first." -ForegroundColor Yellow; return }

$rows = Import-Csv $CsvPath | ForEach-Object {
    [pscustomobject]@{
        Ts       = [datetimeoffset]::Parse($_.timestamp)
        Name     = $_.name
        Percent  = [int]$_.percent
        Charging = ($_.charging -eq 'True')
    }
}
if (@($rows).Count -lt 2) { Write-Host "Not enough data yet ($(@($rows).Count) rows). Need a few % of drain." -ForegroundColor Yellow; return }

$now = [datetimeoffset]::Now

foreach ($grp in ($rows | Group-Object Name)) {
    $name = $grp.Name
    $r    = @($grp.Group | Sort-Object Ts)

    # Build discharge intervals (not charging, % dropped, positive elapsed).
    $intervals = for ($i = 1; $i -lt $r.Count; $i++) {
        $a = $r[$i-1]; $b = $r[$i]
        if ($a.Charging -or $b.Charging) { continue }
        $drop = $a.Percent - $b.Percent
        if ($drop -le 0) { continue }
        $h = ($b.Ts - $a.Ts).TotalHours
        if ($h -le 0) { continue }
        $rate = $drop / $h
        [pscustomobject]@{ Start=$a.Ts; End=$b.Ts; Drop=$drop; Hours=$h; Rate=$rate; Class=$(if ($rate -lt $SleepThreshold) {'sleep'} else {'active'}) }
    }
    $intervals = @($intervals)

    Write-Host ""
    Write-Host "=== $name ===" -ForegroundColor Cyan
    Write-Host ("data: {0} rows, {1} -> {2}  ({3:N1} days)" -f $r.Count, $r[0].Ts.ToString('MM-dd HH:mm'), $r[-1].Ts.ToString('MM-dd HH:mm'), ($r[-1].Ts - $r[0].Ts).TotalDays)
    Write-Host ("now : {0}% ({1})" -f $r[-1].Percent, $(if ($r[-1].Charging) {'charging'} else {'discharging'}))

    if ($intervals.Count -eq 0) { Write-Host "No discharge intervals yet." -ForegroundColor Yellow; continue }

    # Duration-weighted rate over a set of intervals: sum(drop)/sum(hours).
    function Wrate($set) { $s = @($set); if (-not $s.Count) { return $null }; ($s | Measure-Object Drop -Sum).Sum / ($s | Measure-Object Hours -Sum).Sum }

    $active = @($intervals | Where-Object Class -eq 'active')
    $sleep  = @($intervals | Where-Object Class -eq 'sleep')
    $aRate  = Wrate $active
    $sRate  = Wrate $sleep

    if ($aRate) {
        Write-Host ("active drain: {0:N2} %/hr   -> ~{1:N1} h per full charge, ~{2:N0} min per 1%" -f $aRate, (100/$aRate), (60/$aRate))
    } else { Write-Host "active drain: (none observed yet)" }
    if ($sRate) {
        Write-Host ("sleep  drain: {0:N2} %/hr   -> ~{1:N1} days idle per full charge" -f $sRate, (100/$sRate/24))
    } else { Write-Host "sleep  drain: (none observed yet)" }

    # Anomaly: recent active rate vs baseline (older) active rate.
    $recentA   = @($active | Where-Object { $_.End -ge $now.AddHours(-$RecentHours) })
    $baseA     = @($active | Where-Object { $_.End -lt $now.AddHours(-$RecentHours) })
    $recentH   = ($recentA | Measure-Object Hours -Sum).Sum
    $baseH     = ($baseA   | Measure-Object Hours -Sum).Sum

    Write-Host "--- anomaly (active drain, last ${RecentHours}h vs baseline) ---"
    if ($recentH -ge $MinActiveHours -and $baseH -ge $MinActiveHours) {
        $rA = Wrate $recentA; $bA = Wrate $baseA; $ratio = $rA / $bA
        $msg = "recent {0:N2} %/hr vs baseline {1:N2} %/hr = {2:N2}x" -f $rA, $bA, $ratio
        if ($ratio -ge $AnomalyFactor)        { Write-Host ("FASTER THAN USUAL: $msg") -ForegroundColor Red }
        elseif ($ratio -le (1/$AnomalyFactor)){ Write-Host ("slower than usual: $msg") -ForegroundColor Green }
        else                                  { Write-Host ("normal: $msg") -ForegroundColor Green }
    } else {
        Write-Host ("need more history (active-hours recent={0:N1}, baseline={1:N1}; want >= {2} each)" -f $recentH, $baseH, $MinActiveHours) -ForegroundColor Yellow
    }

    # Recent discharge intervals for eyeballing.
    Write-Host "--- last discharge intervals ---"
    $intervals | Select-Object -Last 8 | ForEach-Object {
        Write-Host ("  {0} {1,5:N1}h  -{2}%  {3,5:N2} %/hr  [{4}]" -f $_.Start.ToString('MM-dd HH:mm'), $_.Hours, $_.Drop, $_.Rate, $_.Class)
    }
}

Write-Host ""
Write-Host "(graph: battery-history.csv is plot-ready -- timestamp,percent. Charting comes later.)" -ForegroundColor DarkGray
