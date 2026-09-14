Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-RequiredValue {
    param(
        [Parameter(Mandatory)][string] $Prompt,
        [string] $CurrentValue,
        [switch] $AsSecureString
    )

    while ($true) {
        if ($AsSecureString) {
            $secureValue = Read-Host -Prompt $Prompt -AsSecureString
            $value = [pscredential]::new('restore-user', $secureValue).GetNetworkCredential().Password
        } else {
            $suffix = if ($CurrentValue) { " [$CurrentValue]" } else { '' }
            $value = Read-Host -Prompt "$Prompt$suffix"
            if ([string]::IsNullOrWhiteSpace($value)) {
                $value = $CurrentValue
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
        Write-Warning 'A value is required.'
    }
}

$envFile = Join-Path (Split-Path -Parent $PSScriptRoot) '.env'
if (Test-Path -LiteralPath $envFile -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $envFile) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#') -or -not $trimmed.Contains('=')) {
            continue
        }

        $name, $value = $trimmed.Split('=', 2)
        $name = $name.Trim()
        $value = ($value -replace '\s+#.*$', '').Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
} else {
    Write-Host "No .env file found at '$envFile'; connection details will be requested."
}

if (-not (Get-Command 'pg_restore' -ErrorAction SilentlyContinue)) {
    throw "ERROR: 'pg_restore' not found on PATH."
}

$backupFile = Join-Path $PSScriptRoot 'AdventureWorksPG.gz'
$hostAddress = $env:RW_ENDPOINT
$username = $env:ADMIN_USER
$password = $env:ADMIN_PASSWORD
$databaseName = if ($env:DB_NAME) { $env:DB_NAME } else { 'adventureworks' }

if (-not (Test-Path -LiteralPath $backupFile -PathType Leaf)) {
    throw "AdventureWorks backup '$backupFile' was not found."
}

$hostAddress = Read-RequiredValue -Prompt 'PostgreSQL host address' -CurrentValue $hostAddress
$username = Read-RequiredValue -Prompt 'PostgreSQL username' -CurrentValue $username
if ([string]::IsNullOrWhiteSpace($password)) {
    $password = Read-RequiredValue -Prompt 'PostgreSQL password' -AsSecureString
}

while ($true) {
    Write-Host ''
    Write-Host 'Review the AdventureWorks restore settings:'
    Write-Host "  Host:     $hostAddress"
    Write-Host "  Username: $username"
    Write-Host '  Password: ********'
    Write-Host "  Database: $databaseName"
    Write-Host "  Backup:   $backupFile"
    Write-Host ''

    $action = (Read-Host 'Enter C to confirm, E to edit connection details, or X to cancel').Trim()
    if ($action -in @('c', 'C')) {
        break
    }
    if ($action -in @('x', 'X')) {
        Write-Host 'Restore cancelled; no database changes were made.'
        exit 0
    }
    if ($action -in @('e', 'E')) {
        $hostAddress = Read-RequiredValue -Prompt 'PostgreSQL host address' -CurrentValue $hostAddress
        $username = Read-RequiredValue -Prompt 'PostgreSQL username' -CurrentValue $username
        $databaseName = Read-RequiredValue -Prompt 'PostgreSQL database name' -CurrentValue $databaseName
        $changePassword = Read-Host 'Replace the configured password? [y/N]'
        if ($changePassword -in @('y', 'Y')) {
            $password = Read-RequiredValue -Prompt 'PostgreSQL password' -AsSecureString
        }
        continue
    }
    Write-Warning "Enter 'C', 'E', or 'X'."
}

$env:PGPASSWORD = $password
Write-Host "Restoring '$backupFile' into database '$databaseName' on '$hostAddress'..."
& pg_restore `
    -h $hostAddress `
    -U $username `
    -d $databaseName `
    -O -x -v `
    $backupFile
if ($LASTEXITCODE -ne 0) {
    throw "pg_restore failed with exit code $LASTEXITCODE."
}

Write-Host "AdventureWorks restore completed on '$hostAddress'."