. "$PSScriptRoot\_common.ps1"

Assert-Command 'az'
Assert-Command 'psql'
Assert-Command 'pg_restore'

function Set-FlexibleServerParameter {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Value,
        [string] $CurrentValue,
        [switch] $CompareAsSet
    )

    if (-not $PSBoundParameters.ContainsKey('CurrentValue')) {
        $CurrentValue = (& az postgres flexible-server parameter show `
            --resource-group $resourceGroup --server-name $serverName `
            --name $Name --query value -o tsv --only-show-errors 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "Could not read server parameter '$Name'. $CurrentValue"
        }
    }

    $settingMatches = if ($CompareAsSet) {
        $currentItems = @($CurrentValue -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } |
            Where-Object { $_ } | Sort-Object -Unique)
        $desiredItems = @($Value -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } |
            Where-Object { $_ } | Sort-Object -Unique)
        ($currentItems -join ',') -eq ($desiredItems -join ',')
    } else {
        $CurrentValue.Trim() -eq $Value.Trim()
    }
    if ($settingMatches) {
        Write-Host "Skipping setting $Name=$Value; it is already set according to the script."
        return
    }

    Write-Host "Setting server parameter $Name=$Value..."
    Invoke-NativeCommand az postgres flexible-server parameter set `
        --resource-group $resourceGroup --server-name $serverName `
        --name $Name --value $Value --only-show-errors -o none
}

$databaseName = 'adventureworks'
$databaseDirectory = Join-Path $RepoRoot 'database'
$configuredLocalFile = $env:AdventureWorks_Localfile
$downloadUrl = $env:AdventureWorks_URL
$resourceGroup = Assert-EnvironmentVariable 'RESOURCE_GROUP'
$serverName = Get-PrimaryServerName

Set-AzureSubscription

$maintenanceConnection = Get-ReadWriteConnection -DatabaseName 'postgres'
$databaseConnection = Get-ReadWriteConnection -DatabaseName $databaseName
$databaseExists = (& psql $maintenanceConnection -tAq -v ON_ERROR_STOP=1 `
    -c "SELECT 1 FROM pg_database WHERE datname = '$databaseName';" 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Could not connect to the primary server to check database '$databaseName'. $databaseExists"
}

$restoreDatabase = $true
$recreateDatabaseApproved = $false
if ($databaseExists -eq '1') {
    $recreateDatabase = Read-Host "Database '$databaseName' already exists. Drop and recreate it? ALL DATA WILL BE LOST. Enter Y to restore it or any other value to skip the restore [y/N]"
    if ($recreateDatabase -notin @('y', 'Y')) {
        Write-Host "Skipping the AdventureWorks restore; existing database '$databaseName' will not be changed."
        $restoreDatabase = $false
    } else {
        $recreateDatabaseApproved = $true
    }
}

$confirmation = Read-Host @"
WARNING: This script will prepare Azure Database for PostgreSQL server '$serverName'
in resource group '$resourceGroup' for the AdventureWorks restore.

The following server parameter values will be ensured:
    - azure.extensions includes tablefunc and uuid-ossp
        (any extensions already allowlisted will be preserved)
    - pg_stat_statements.save = on
    - pg_stat_statements.track_planning = on
    - pg_stat_statements.track = all
    - pg_stat_statements.track_utility = on

Tracking planning and all statements can add monitoring overhead. The restore will
retain the tablefunc and uuid-ossp extension objects from the dump.

Apply these settings and continue? [y/N]
"@
if ($confirmation -notin @('y', 'Y')) {
        Write-Host 'Cancelled; no server parameters or database objects were changed.'
        exit 0
}

$currentAzureExtensions = (& az postgres flexible-server parameter show `
    --resource-group $resourceGroup --server-name $serverName `
    --name 'azure.extensions' --query value -o tsv --only-show-errors 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Could not read server parameter 'azure.extensions'. $currentAzureExtensions"
}
$requiredAzureExtensions = @('tablefunc', 'uuid-ossp')
$azureExtensions = @($currentAzureExtensions -split ',' | Where-Object { $_ } | ForEach-Object { $_.Trim() })
$azureExtensions = @($azureExtensions + $requiredAzureExtensions | Sort-Object -Unique)
Set-FlexibleServerParameter -Name 'azure.extensions' -Value ($azureExtensions -join ',') `
    -CurrentValue $currentAzureExtensions -CompareAsSet
Set-FlexibleServerParameter -Name 'pg_stat_statements.save' -Value 'on'
Set-FlexibleServerParameter -Name 'pg_stat_statements.track_planning' -Value 'on'
Set-FlexibleServerParameter -Name 'pg_stat_statements.track' -Value 'all'
Set-FlexibleServerParameter -Name 'pg_stat_statements.track_utility' -Value 'on'

if (-not $restoreDatabase) {
    Write-Host 'Server parameter processing completed; AdventureWorks restore was skipped.'
    exit 0
}

if ($configuredLocalFile) {
    $dumpFile = if ([IO.Path]::IsPathRooted($configuredLocalFile)) {
        $configuredLocalFile
    } else {
        Join-Path $RepoRoot $configuredLocalFile
    }
} else {
    $dumpFile = Join-Path $databaseDirectory 'adventureworks.dump'
}

if (-not (Test-Path -LiteralPath $dumpFile -PathType Leaf)) {
    if ([string]::IsNullOrWhiteSpace($downloadUrl)) {
        throw "AdventureWorks dump '$dumpFile' was not found and AdventureWorks_URL is blank in .env."
    }

    if (-not (Test-Path -LiteralPath $databaseDirectory)) {
        $null = New-Item -ItemType Directory -Path $databaseDirectory -Force
    }
    $dumpFile = Join-Path $databaseDirectory 'adventureworks.dump'
    $temporaryFile = "$dumpFile.download"
    Write-Host "Downloading AdventureWorks dump from '$downloadUrl'..."
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $temporaryFile -UseBasicParsing
        Move-Item -LiteralPath $temporaryFile -Destination $dumpFile -Force
    } catch {
        Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
        throw "Could not download AdventureWorks_URL '$downloadUrl'. $($_.Exception.Message)"
    }
    Set-EnvironmentFileValues @{ AdventureWorks_Localfile = $dumpFile }
    Write-Host "Saved AdventureWorks_Localfile=$dumpFile to .env."
} else {
    Write-Host "Using AdventureWorks dump '$dumpFile'."
}

$archiveOutput = (& pg_restore --list $dumpFile 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "AdventureWorks dump '$dumpFile' is not a valid PostgreSQL archive. $archiveOutput"
}

if ($recreateDatabaseApproved) {
    Write-Host "Dropping database '$databaseName'..."
    Invoke-NativeCommand psql $maintenanceConnection -v ON_ERROR_STOP=1 `
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$databaseName' AND pid <> pg_backend_pid();"
    Invoke-NativeCommand psql $maintenanceConnection -v ON_ERROR_STOP=1 `
        -c "DROP DATABASE $databaseName;"
}

Write-Host "Creating database '$databaseName'..."
Invoke-NativeCommand psql $maintenanceConnection -v ON_ERROR_STOP=1 `
    -c "CREATE DATABASE $databaseName;"

# Write-Host "Removing the default 'public' schema so the dump can recreate it..."
# Invoke-NativeCommand psql $databaseConnection -v ON_ERROR_STOP=1 `
#     -c 'DROP SCHEMA public CASCADE;'

Write-Host "Restoring '$dumpFile' into database '$databaseName'..."
$restoreListFile = Join-Path ([IO.Path]::GetTempPath()) "adventureworks-$([guid]::NewGuid().ToString('N')).list"
try {
    $restoreList = $archiveOutput -split "`r?`n" |
        Where-Object { $_ -notmatch '\bEXTENSION\b' -or $_ -match '\b(tablefunc|uuid-ossp)\b' }
    [IO.File]::WriteAllLines($restoreListFile, $restoreList, [Text.UTF8Encoding]::new($false))
    Invoke-NativeCommand pg_restore `
        --dbname $databaseConnection `
        --no-owner --no-privileges --exit-on-error `
        --use-list $restoreListFile `
        $dumpFile
} finally {
    Remove-Item -LiteralPath $restoreListFile -Force -ErrorAction SilentlyContinue
}

Write-Host "AdventureWorks restore completed on $($env:RW_ENDPOINT)."