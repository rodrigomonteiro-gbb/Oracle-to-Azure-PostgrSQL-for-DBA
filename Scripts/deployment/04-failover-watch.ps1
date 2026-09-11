param(
    [ValidateSet('ro', 'rw')]
    [string] $Mode = 'ro',
    [ValidateRange(1, 10)]
    [int] $FailureThreshold = 2,
    [ValidateRange(0, 60)]
    [int] $ConnectTimeout = 0
)

. "$PSScriptRoot\_common.ps1"
Assert-Command 'psql'

if ($Mode -eq 'rw') {
    if ($ConnectTimeout -eq 0) { $ConnectTimeout = 2 }
    $connection = "$(Get-ReadWriteConnection) connect_timeout=$ConnectTimeout"
    $endpointLabel = 'read/write endpoint'
} else {
    if ($ConnectTimeout -eq 0) { $ConnectTimeout = 5 }
    $connection = "$(Get-ReadOnlyConnection) connect_timeout=$ConnectTimeout"
    $endpointLabel = 'read replica'
}

Write-Host "Watching the $endpointLabel continuously (connect timeout: ${ConnectTimeout}s)."
Write-Host "Trigger primary HA failover with: az postgres flexible-server restart -g $($env:RESOURCE_GROUP) -n $(Get-PrimaryServerName) --failover Forced"
Write-Host 'Ctrl-C to stop.'
Write-Host '------------------------------------------------------------------------------'

$serving = $null
$firstFailureAt = 0L
$consecutiveFailures = 0
while ($true) {
    $probeStartedAt = [Diagnostics.Stopwatch]::StartNew()
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $probeOutput = [string](& psql $connection -tAq -v ON_ERROR_STOP=1 `
            -c 'select pg_is_in_recovery()' 2>&1 | Out-String)
        $probeExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($probeExitCode -eq 0) {
        $consecutiveFailures = 0
        if ($probeOutput.Trim() -eq 'f') {
            $line = 'up   - primary, accepting writes'
            $isServing = $true
        } else {
            $line = 'up   - replica, serving reads'
            $isServing = $Mode -ne 'rw'
        }
    } else {
        if ($consecutiveFailures -eq 0) {
            $firstFailureAt = $now
        }
        $consecutiveFailures++
        if ($consecutiveFailures -lt $FailureThreshold) {
            $line = "retrying after transient connection failure ($consecutiveFailures/$FailureThreshold)"
            Write-Host "$timestamp   $line"
            $probeStartedAt.Stop()
            $remainingDelay = 1000 - $probeStartedAt.ElapsedMilliseconds
            if ($remainingDelay -gt 0) {
                Start-Sleep -Milliseconds $remainingDelay
            }
            continue
        }
        $line = 'DOWN - not reachable'
        $isServing = $false
    }

    if ($isServing) {
        if ($serving -eq $false) {
            $gap = $now - $firstFailureAt
            Write-Host ">>>>>> FAILOVER: $endpointLabel was unavailable for ~$($gap)s <<<<<<"
        }
        $serving = $true
    } else {
        if ($serving -ne $false -and $consecutiveFailures -ge $FailureThreshold) {
            Write-Host "Connection error: $($probeOutput.Trim())"
        }
        $serving = $false
    }

    Write-Host "$timestamp   $line"
    $probeStartedAt.Stop()
    $remainingDelay = 1000 - $probeStartedAt.ElapsedMilliseconds
    if ($remainingDelay -gt 0) {
        Start-Sleep -Milliseconds $remainingDelay
    }
}