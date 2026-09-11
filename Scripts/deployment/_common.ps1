Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $ScriptDir
$envFile = Join-Path $RepoRoot '.env'

# Keep this project independent from broken or inaccessible global CLI extensions.
if (-not $env:AZURE_EXTENSION_DIR) {
    $env:AZURE_EXTENSION_DIR = Join-Path $env:LOCALAPPDATA 'Azure-PostgreSQL\cliextensions'
}
if (-not (Test-Path -LiteralPath $env:AZURE_EXTENSION_DIR)) {
    $null = New-Item -ItemType Directory -Path $env:AZURE_EXTENSION_DIR -Force
}

if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
    [Console]::Error.WriteLine('ERROR: no .env file found.')
    [Console]::Error.WriteLine('Fresh deploy:     Copy-Item .env.example .env  (then edit it)')
    [Console]::Error.WriteLine('Existing cluster: .\scripts\bootstrap-env.ps1  (rebuilds .env from Azure)')
    exit 1
}

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

if (-not $env:DB_NAME) {
    $env:DB_NAME = 'postgres'
}
$env:PGPASSWORD = $env:ADMIN_PASSWORD

function Assert-EnvironmentVariable {
    param([Parameter(Mandatory)][string] $Name)

    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$Name not set in .env"
    }
    return $value
}

function Get-PrimaryServerName {
    if ($env:SERVER_NAME) {
        return $env:SERVER_NAME
    }
    return Assert-EnvironmentVariable 'CLUSTER_NAME'
}

function Get-ReplicaServerName {
    if ($env:REPLICA_NAME) {
        return $env:REPLICA_NAME
    }
    return "$(Get-PrimaryServerName)-replica"
}

function Get-ReadWriteConnection {
    param([string] $DatabaseName = $env:DB_NAME)

    $user = Assert-EnvironmentVariable 'ADMIN_USER'
    $null = Assert-EnvironmentVariable 'ADMIN_PASSWORD'
    $endpoint = Assert-EnvironmentVariable 'RW_ENDPOINT'
    return "host=$endpoint port=5432 dbname=$DatabaseName user=$user sslmode=require"
}

function Get-ReadOnlyConnection {
    param([string] $DatabaseName = $env:DB_NAME)

    $user = Assert-EnvironmentVariable 'ADMIN_USER'
    $null = Assert-EnvironmentVariable 'ADMIN_PASSWORD'
    $endpoint = Assert-EnvironmentVariable 'RO_ENDPOINT'
    return "host=$endpoint port=5432 dbname=$DatabaseName user=$user sslmode=require"
}

function Assert-Command {
    param([Parameter(Mandatory)][string] $Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "ERROR: '$Name' not found on PATH."
    }
}

function Invoke-NativeCommand {
    param([string] $NativeExecutablePath)

    & $NativeExecutablePath @args
    if ($LASTEXITCODE -ne 0) {
        throw "Command '$NativeExecutablePath' failed with exit code $LASTEXITCODE."
    }
}

function Set-AzureSubscription {
    Assert-Command 'az'
    if ($env:SUBSCRIPTION) {
        & az account set --subscription $env:SUBSCRIPTION 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "ERROR: couldn't switch to SUBSCRIPTION='$($env:SUBSCRIPTION)'. Check the name/id and your access (run 'az login')."
        }
    }

    $subscription = (& az account show --query name -o tsv 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($subscription)) {
        throw "ERROR: not logged in. Run 'az login'."
    }
    Write-Host "Active subscription: $subscription"
    if (-not $env:SUBSCRIPTION) {
        Write-Host "(Tip: set SUBSCRIPTION in .env to pin this and skip manual 'az account set'.)"
    }
}

function Set-EnvironmentFileValues {
    param([Parameter(Mandatory)][hashtable] $Values)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]](Get-Content -LiteralPath $envFile))
    foreach ($entry in $Values.GetEnumerator()) {
        $index = -1
        for ($position = 0; $position -lt $lines.Count; $position++) {
            if ($lines[$position] -match "^$([regex]::Escape($entry.Key))=") {
                $index = $position
                break
            }
        }
        $newLine = "$($entry.Key)=$($entry.Value)"
        if ($index -ge 0) {
            $lines[$index] = $newLine
        } else {
            $lines.Add($newLine)
        }
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
    Set-Content -LiteralPath $envFile -Value $lines -Encoding utf8
}

function Set-EndpointsInEnvironmentFile {
    param(
        [Parameter(Mandatory)][string] $ReadWriteEndpoint,
        [Parameter(Mandatory)][string] $ReadOnlyEndpoint
    )

    Set-EnvironmentFileValues @{
        RW_ENDPOINT = $ReadWriteEndpoint
        RO_ENDPOINT = $ReadOnlyEndpoint
    }
}