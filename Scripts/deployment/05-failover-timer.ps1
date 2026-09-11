param(
    [ValidateSet('ro', 'rw')]
    [string] $Mode = 'rw'
)

. "$PSScriptRoot\_common.ps1"
Assert-Command 'psql'

if ($Mode -eq 'ro') {
    $connection = "$(Get-ReadOnlyConnection) connect_timeout=2"
    $label = 'reader'
    $readyState = 'READONLY'
} else {
    $connection = "$(Get-ReadWriteConnection) connect_timeout=2"
    $label = 'read/write'
    $readyState = 'WRITABLE'
}

Write-Host "Timing the $label path. Wait for '-> $readyState', then run: az postgres flexible-server restart -g $($env:RESOURCE_GROUP) -n $(Get-PrimaryServerName) --failover Forced"
Write-Host 'Ctrl-C to stop.'
$state = $null
$stateStartedAt = 0L
while ($true) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $timestamp = Get-Date -Format 'HH:mm:ss.fff'
    $output = (& psql $connection -tAq -c 'select pg_is_in_recovery()' 2>$null)
    if ($LASTEXITCODE -eq 0) {
        $newState = if ($output.Trim() -eq 'f') { 'WRITABLE' } else { 'READONLY' }
    } else {
        $newState = 'DOWN'
    }

    if ($newState -ne $state) {
        if ($null -ne $state) {
            Write-Host "$timestamp  -> $newState   (was $state for $($now - $stateStartedAt) ms)"
        } else {
            Write-Host "$timestamp  -> $newState"
        }
        $state = $newState
        $stateStartedAt = $now
    }
    Start-Sleep -Milliseconds 50
}