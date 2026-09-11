[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $ReadCount
)

. "$PSScriptRoot\_common.ps1"

Assert-Command 'psql'
$connection = Get-ReadOnlyConnection -DatabaseName 'adventureworks'
$env:PGCONNECT_TIMEOUT = '15'

Write-Host "Checking read replica connectivity ($($env:RO_ENDPOINT))..."
$recoveryState = $null
for ($attempt = 1; $attempt -le 5; $attempt++) {
    $recoveryState = (& psql $connection -X -tAq -v ON_ERROR_STOP=1 `
        -c 'select pg_is_in_recovery()' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0) {
        break
    }
    if ($attempt -eq 5) {
        throw "The read replica PostgreSQL data plane did not accept connections after 5 attempts. Azure may report the server as Ready while replica recovery is unhealthy. Last error: $recoveryState"
    }
    Write-Warning "Replica connection attempt $attempt failed; retrying in 15 seconds..."
    Start-Sleep -Seconds 15
}
if ($recoveryState -ne 't') {
    throw "RO_ENDPOINT is queryable but is not a read replica (pg_is_in_recovery() returned '$recoveryState')."
}

$readScript = Join-Path $RepoRoot 'sql\read-queries - AdventureWorks.sql'
if ($PSBoundParameters.ContainsKey('ReadCount')) {
    for ($readNumber = 1; $readNumber -le $ReadCount; $readNumber++) {
        Write-Host "Read $readNumber out of $ReadCount" -ForegroundColor Green
        Invoke-NativeCommand psql $connection -v ON_ERROR_STOP=1 -f $readScript
    }
} else {
    Write-Host 'Reading continuously. Press any key to stop.' -ForegroundColor Yellow
    $readNumber = 0
    while (-not [Console]::KeyAvailable) {
        $readNumber++
        Invoke-NativeCommand psql $connection -v ON_ERROR_STOP=1 -f $readScript
        Write-Host "Continuous read $readNumber completed. Press any key to stop." -ForegroundColor Yellow
    }
    $null = [Console]::ReadKey($true)
    Write-Host 'Continuous read stopped.' -ForegroundColor Yellow
}

Write-Host "`nVerifying that transactions are read-only..."
$readOnlyState = (& psql $connection -X -tAq -v ON_ERROR_STOP=1 `
    -c 'show transaction_read_only' 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Could not verify transaction_read_only: $readOnlyState"
}
if ($readOnlyState -ne 'on') {
    throw "Unexpected transaction_read_only value '$readOnlyState' on the replica."
}
Write-Host '>> Read replica confirmed: recovery is active and transactions are read-only.'