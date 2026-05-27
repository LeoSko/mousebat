param(
    [string]$DeviceId   = "dev00000001",   # Logitech G PRO 2 LIGHTSPEED
    [int]$PollSeconds    = 60,              # how often to poll the local HTTP server
    [double]$FullMin     = 95.0,            # charge-stop above this % counts as "full"
    [double]$LowThresh   = 5.0,             # warn when battery drops below this %
    [double]$LowRearm    = 10.0             # re-arm low warning once back above this %
)

$endpoint = "http://localhost:12321/device/$DeviceId"
$logo     = Join-Path $PSScriptRoot 'applogo.png'
Import-Module BurntToast -ErrorAction SilentlyContinue

New-BurntToastNotification -Text "Mouse battery watcher armed", "Pings on full charge and below ${LowThresh}%." -AppLogo $logo -UniqueIdentifier "lg-armed" | Out-Null

$prevCharging = $null    # tri-state: $null until first successful read
$lowNotified  = $false   # debounce so low warning fires once per drain cycle

while ($true) {
    try {
        $resp = Invoke-WebRequest -Uri $endpoint -UseBasicParsing -TimeoutSec 5
        $dev  = ([xml]$resp.Content).xml
        $pct  = [double]$dev.battery_percent
        $isCharging = "$($dev.charging)".Trim().ToLower() -in @("true","charging","1")

        # --- Full charge: falling edge of charging flag at high %. ---
        if ($prevCharging -eq $true -and -not $isCharging -and $pct -ge $FullMin) {
            New-BurntToastNotification -Text "Mouse fully charged", ("PRO 2 at {0:N0}% - unplug it." -f $pct) -AppLogo $logo -UniqueIdentifier "lg-full"
        }

        # --- Low battery: below threshold, not charging, fire once per cycle. ---
        if (-not $isCharging -and $pct -lt $LowThresh -and -not $lowNotified) {
            New-BurntToastNotification -Text "Mouse battery low", ("PRO 2 at {0:N0}% - charge it." -f $pct) -AppLogo $logo -UniqueIdentifier "lg-low"
            $lowNotified = $true
        }
        # Re-arm the low warning once recovered (charging or back above re-arm %).
        if ($isCharging -or $pct -ge $LowRearm) { $lowNotified = $false }

        $prevCharging = $isCharging
    }
    catch {
        # server not up yet / transient - keep state, retry next loop
    }
    Start-Sleep -Seconds $PollSeconds
}
