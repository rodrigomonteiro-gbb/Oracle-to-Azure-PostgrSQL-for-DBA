param(
    [Alias('ClusterName')]
    [string] $ServerName
)

. "$PSScriptRoot\_common.ps1"

function Wait-FlexibleServerReady {
    param(
        [Parameter(Mandatory)][string] $Name,
        [int] $StableObservations = 1
    )

    Write-Host "Waiting for server '$Name' to become ready..."
    $readyDeadline = (Get-Date).AddMinutes(30)
    $readyObservations = 0
    do {
        $serverState = (& az postgres flexible-server show `
            --name $Name --resource-group $resourceGroup `
            --query state -o tsv --only-show-errors 2>$null)
        if ($LASTEXITCODE -ne 0) {
            throw "Could not read the state of server '$Name'."
        }
        if ($serverState -eq 'Ready') {
            $readyObservations++
            if ($readyObservations -ge $StableObservations) {
                break
            }
        } else {
            $readyObservations = 0
        }
        if ($serverState -in @('Disabled', 'Dropping')) {
            throw "Server '$Name' entered terminal state '$serverState'."
        }
        if ((Get-Date) -ge $readyDeadline) {
            throw "Timed out waiting for server '$Name' to become ready. Current state: '$serverState'."
        }
        Write-Host "  Current state: $serverState; checking again in 15 seconds..."
        Start-Sleep -Seconds 15
    } while ($true)
    Write-Host "Server '$Name' is ready."
}

function Wait-PostgresReadReplicaReady {
    param([Parameter(Mandatory)][string] $Connection)

    Write-Host 'Waiting for the read replica PostgreSQL data plane...'
    $readyDeadline = (Get-Date).AddMinutes(20)
    do {
        $recoveryState = (& psql $Connection -X -tAq -v ON_ERROR_STOP=1 `
            -c 'select pg_is_in_recovery()' 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -eq 0) {
            if ($recoveryState -ne 't') {
                throw "The reader endpoint responded but is not in recovery (pg_is_in_recovery() returned '$recoveryState')."
            }
            Write-Host 'Read replica PostgreSQL data plane is ready.'
            return
        }
        if ((Get-Date) -ge $readyDeadline) {
            throw "Timed out waiting for the read replica PostgreSQL data plane. Azure may report the server as Ready while replica recovery is unhealthy. Last error: $recoveryState"
        }
        Write-Host '  PostgreSQL is not accepting replica connections yet; checking again in 15 seconds...'
        Start-Sleep -Seconds 15
    } while ($true)
}

function Show-ExistingDeploymentResources {
    $existingResources = [System.Collections.Generic.List[object]]::new()
    $existingResourceKeys = [System.Collections.Generic.HashSet[string]]::new()

    $resourceGroupLocation = (& az group show --name $resourceGroup `
        --query location -o tsv --only-show-errors 2>$null)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n== Existing deployment resources =="
        Write-Host "None found for resource group '$resourceGroup'."
        Write-Host
        return $false
    }

    $null = $existingResourceKeys.Add('resource-group')
    $existingResources.Add([pscustomobject]@{
        Type = 'Resource group'
        Name = $resourceGroup
        Details = "Location: $resourceGroupLocation"
    })

    foreach ($server in @(
            @{ Name = $ServerName; Type = 'Primary server'; Key = 'primary' },
            @{ Name = $replicaName; Type = 'Read replica'; Key = 'replica' }
        )) {
        $serverDetails = (& az postgres flexible-server show `
            --name $server.Name --resource-group $resourceGroup `
            --query "join('|', [state, fullyQualifiedDomainName])" `
            -o tsv --only-show-errors 2>$null)
        if ($LASTEXITCODE -ne 0) {
            continue
        }

        $state, $fqdn = $serverDetails -split '\|', 2
        $null = $existingResourceKeys.Add($server.Key)
        $existingResources.Add([pscustomobject]@{
            Type = $server.Type
            Name = $server.Name
            Details = "State: $state; Endpoint: $fqdn"
        })

        foreach ($ruleName in @('AllowScriptClient', 'Client-Range')) {
            $firewallRange = (& az postgres flexible-server firewall-rule show `
                --name $server.Name --resource-group $resourceGroup `
                --rule-name $ruleName `
                --query "join('|', [startIpAddress, endIpAddress])" `
                -o tsv --only-show-errors 2>$null)
            if ($LASTEXITCODE -eq 0) {
                $rangeStart, $rangeEnd = $firewallRange -split '\|', 2
                $null = $existingResourceKeys.Add("$($server.Key)/$ruleName")
                $existingResources.Add([pscustomobject]@{
                    Type = "$($server.Type) firewall"
                    Name = $ruleName
                    Details = "$rangeStart - $rangeEnd"
                })
            }
        }
    }

    $database = (& az postgres flexible-server db show `
        --server-name $ServerName --resource-group $resourceGroup `
        --database-name $databaseName --query name -o tsv --only-show-errors 2>$null)
    if ($LASTEXITCODE -eq 0 -and $database) {
        $null = $existingResourceKeys.Add('database')
        $existingResources.Add([pscustomobject]@{
            Type = 'Database'
            Name = $database
            Details = "Server: $ServerName"
        })
    }

    Write-Host "`n== Existing deployment resources =="
    $existingResources | Format-Table Type, Name, Details -AutoSize | Out-Host

    $expectedResourceKeys = @(
        'resource-group',
        'primary',
        'primary/AllowScriptClient',
        'replica',
        'replica/AllowScriptClient',
        'database'
    )
    if ($hasClientIpRange) {
        $expectedResourceKeys += @('primary/Client-Range', 'replica/Client-Range')
    }
    return @($expectedResourceKeys | Where-Object { -not $existingResourceKeys.Contains($_) }).Count -eq 0
}

Assert-Command 'az'
Assert-Command 'psql'
$resourceGroup = Assert-EnvironmentVariable 'RESOURCE_GROUP'
$location = Assert-EnvironmentVariable 'LOCATION'
$databaseName = Assert-EnvironmentVariable 'DB_NAME'
if ($databaseName -notmatch '^[A-Za-z0-9_-]{1,63}$') {
    throw 'DB_NAME must be 1-63 characters and contain only letters, numbers, underscores, and hyphens.'
}
$configuredServerName = Get-PrimaryServerName
if ([string]::IsNullOrWhiteSpace($ServerName)) {
    $enteredServerName = Read-Host "Primary server name [$configuredServerName]"
    $ServerName = if ([string]::IsNullOrWhiteSpace($enteredServerName)) {
        $configuredServerName
    } else {
        $enteredServerName.Trim()
    }
}
if ($ServerName -notmatch '^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])$') {
    throw 'Server name must be 3-63 characters, contain only lowercase letters, numbers, and hyphens, and not start or end with a hyphen.'
}
$replicaName = if ($env:REPLICA_NAME) { $env:REPLICA_NAME } else { "$ServerName-replica" }
if ($replicaName -notmatch '^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])$') {
    throw 'REPLICA_NAME must be 3-63 characters, contain only lowercase letters, numbers, and hyphens, and not start or end with a hyphen.'
}
$adminUser = Assert-EnvironmentVariable 'ADMIN_USER'
$adminPassword = Assert-EnvironmentVariable 'ADMIN_PASSWORD'
$pgVersion = if ($env:PG_VERSION) { $env:PG_VERSION } else { '17' }
$skuName = if ($env:SKU_NAME) { $env:SKU_NAME } elseif ($env:VCORES) { "Standard_D$($env:VCORES)s_v3" } else { 'Standard_D2s_v3' }
$tier = if ($env:TIER) { $env:TIER } else { 'GeneralPurpose' }
$storageSize = if ($env:STORAGE_SIZE_GB) { $env:STORAGE_SIZE_GB } else { '128' }
$zonalResiliency = if ($env:ZONAL_RESILIENCY) { $env:ZONAL_RESILIENCY } else { 'Enabled' }
if ($zonalResiliency -notin @('Enabled', 'Disabled')) {
    throw 'ZONAL_RESILIENCY must be Enabled or Disabled.'
}
$highAvailabilityMode = $env:HIGH_AVAILABILITY_MODE
if ($zonalResiliency -eq 'Enabled' -and $highAvailabilityMode -and $highAvailabilityMode -ne 'Zonal') {
    throw 'HIGH_AVAILABILITY_MODE must be Zonal or left blank.'
}
$geoRedundancy = if ($env:GEO_REDUNDANCY) { $env:GEO_REDUNDANCY } else { 'Disabled' }
if ($geoRedundancy -notin @('Enabled', 'Disabled')) {
    throw 'GEO_REDUNDANCY must be Enabled or Disabled.'
}
$clientIpAddress = $env:CLIENT_IP_ADDRESS
$clientIpWasDetected = $false
if ([string]::IsNullOrWhiteSpace($clientIpAddress)) {
    $detectClientIp = Read-Host 'CLIENT_IP_ADDRESS is blank. Detect this machine public IPv4 address and save it to .env? [y/N]'
    if ($detectClientIp -notin @('y', 'Y')) {
        throw 'Set CLIENT_IP_ADDRESS in .env and rerun this script.'
    }
    try {
        $clientIpAddress = ([string](Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 15)).Trim()
    } catch {
        throw 'Could not detect this machine public IP. Set CLIENT_IP_ADDRESS in .env and rerun.'
    }
    $clientIpWasDetected = $true
}
$parsedClientIp = $null
if (-not [Net.IPAddress]::TryParse($clientIpAddress, [ref]$parsedClientIp) -or
    $parsedClientIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
    throw "CLIENT_IP_ADDRESS must be a valid IPv4 address; received '$clientIpAddress'."
}
if ($clientIpWasDetected) {
    Set-EnvironmentFileValues @{ CLIENT_IP_ADDRESS = $clientIpAddress }
    Write-Host "Saved CLIENT_IP_ADDRESS=$clientIpAddress to .env."
}
$startIpAddress = $clientIpAddress
$endIpAddress = $clientIpAddress
$clientIpRangeStart = $env:CLIENT_IP_RANGE_START
$clientIpRangeEnd = $env:CLIENT_IP_RANGE_END
$hasClientIpRange = -not [string]::IsNullOrWhiteSpace($clientIpRangeStart) -or
    -not [string]::IsNullOrWhiteSpace($clientIpRangeEnd)
if ($hasClientIpRange) {
    if ([string]::IsNullOrWhiteSpace($clientIpRangeStart) -or
        [string]::IsNullOrWhiteSpace($clientIpRangeEnd)) {
        throw 'CLIENT_IP_RANGE_START and CLIENT_IP_RANGE_END must both be set or both be blank.'
    }
    $parsedRangeStart = $null
    $parsedRangeEnd = $null
    if (-not [Net.IPAddress]::TryParse($clientIpRangeStart, [ref]$parsedRangeStart) -or
        $parsedRangeStart.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw "CLIENT_IP_RANGE_START must be a valid IPv4 address; received '$clientIpRangeStart'."
    }
    if (-not [Net.IPAddress]::TryParse($clientIpRangeEnd, [ref]$parsedRangeEnd) -or
        $parsedRangeEnd.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw "CLIENT_IP_RANGE_END must be a valid IPv4 address; received '$clientIpRangeEnd'."
    }
    $rangeStartNumber = [BitConverter]::ToUInt32($parsedRangeStart.GetAddressBytes()[3..0], 0)
    $rangeEndNumber = [BitConverter]::ToUInt32($parsedRangeEnd.GetAddressBytes()[3..0], 0)
    if ($rangeStartNumber -gt $rangeEndNumber) {
        throw 'CLIENT_IP_RANGE_START must not be greater than CLIENT_IP_RANGE_END.'
    }
}

Set-AzureSubscription
$allResourcesExist = Show-ExistingDeploymentResources
$recreateDatabaseApproved = $false
if ($allResourcesExist) {
    $continueDeployment = Read-Host 'All expected resources already exist. Continue deployment processing? [y/N]'
    if ($continueDeployment -notin @('y', 'Y')) {
        Write-Host 'Deployment stopped; no resources were changed.'
        exit 0
    }

    if ($databaseName -in @('postgres', 'azure_maintenance', 'azure_sys', 'template0', 'template1')) {
        throw "Database '$databaseName' is protected and cannot be destroyed by this script."
    }
    $destroyDatabase = Read-Host "Destroy and recreate database '$databaseName'? ALL DATA WILL BE LOST. [y/N]"
    if ($destroyDatabase -notin @('y', 'Y')) {
        Write-Host 'Deployment stopped; the existing database was not changed.'
        exit 0
    }
    $recreateDatabaseApproved = $true
}

$existingLocation = (& az group show --name $resourceGroup --query location -o tsv 2>$null)
if ($LASTEXITCODE -eq 0 -and $existingLocation) {
    if ($existingLocation -ne $location) {
        Write-Host "Note: resource group '$resourceGroup' already exists in '$existingLocation'."
        Write-Host "      Using that region and ignoring LOCATION=$location from .env."
        $location = $existingLocation
    }
} else {
    Write-Host "Creating resource group '$resourceGroup' in '$location'..."
    Invoke-NativeCommand az group create --name $resourceGroup --location $location -o none
}

$existingServer = (& az postgres flexible-server show --name $ServerName --resource-group $resourceGroup --only-show-errors -o json 2>$null | Out-String)
$primaryWasCreated = $false
if ($LASTEXITCODE -eq 0 -and $existingServer) {
    Write-Host "Primary server '$ServerName' already exists in '$resourceGroup'; reusing it."
    $existingGeoRedundancy = ($existingServer | ConvertFrom-Json).backup.geoRedundantBackup
    if ($existingGeoRedundancy -ne $geoRedundancy) {
        Write-Warning "GEO_REDUNDANCY=$geoRedundancy was requested, but existing server '$ServerName' is configured as '$existingGeoRedundancy'. Azure only allows this setting during server creation; recreate the server to change it."
    } else {
        Write-Host "Geo-redundant backup matches GEO_REDUNDANCY=$geoRedundancy."
    }
} else {
    Write-Host "Deploying primary server '$ServerName' to '$location' (several minutes)..."
    $createArguments = @(
        'postgres', 'flexible-server', 'create',
        '--name', $ServerName, '--resource-group', $resourceGroup, '--location', $location,
        '--admin-user', $adminUser, '--admin-password', $adminPassword,
        '--version', $pgVersion, '--sku-name', $skuName, '--tier', $tier,
        '--storage-size', $storageSize, '--zonal-resiliency', $zonalResiliency,
        '--geo-redundant-backup', $geoRedundancy,
        '--public-access', $clientIpAddress, '--yes', '--only-show-errors'
    )
    if ($zonalResiliency -eq 'Enabled' -and $highAvailabilityMode -eq 'Zonal') {
        $createArguments += '--allow-same-zone'
    }
    Invoke-NativeCommand az @createArguments
    $primaryWasCreated = $true
}

$requiredReadyObservations = if ($primaryWasCreated) { 3 } else { 1 }
Wait-FlexibleServerReady -Name $ServerName -StableObservations $requiredReadyObservations

$primaryPublicAccess = (& az postgres flexible-server show --name $ServerName `
    --resource-group $resourceGroup --query network.publicNetworkAccess -o tsv --only-show-errors)
if ($LASTEXITCODE -ne 0) { throw "Could not read network configuration for '$ServerName'." }
if ($primaryPublicAccess -ne 'Enabled') {
    Write-Host "Enabling public network access on primary server '$ServerName'..."
    Invoke-NativeCommand az postgres flexible-server update `
        --name $ServerName --resource-group $resourceGroup `
        --public-access Enabled --only-show-errors
    Wait-FlexibleServerReady -Name $ServerName -StableObservations 3
} else {
    Write-Host "Public network access is already enabled on primary server '$ServerName'."
}
$primaryFirewallRange = (& az postgres flexible-server firewall-rule show `
    --name $ServerName --resource-group $resourceGroup --rule-name AllowScriptClient `
    --query "join(',', [startIpAddress, endIpAddress])" -o tsv --only-show-errors 2>$null)
if ($LASTEXITCODE -ne 0 -or $primaryFirewallRange.Trim() -ne "$startIpAddress,$endIpAddress") {
    Write-Host "Allowing client IP $clientIpAddress on the primary..."
    Invoke-NativeCommand az postgres flexible-server firewall-rule create `
        --name $ServerName --resource-group $resourceGroup `
        --rule-name AllowScriptClient --start-ip-address $startIpAddress `
        --end-ip-address $endIpAddress --only-show-errors
} else {
    Write-Host "Primary firewall already allows client IP $clientIpAddress."
}
if ($hasClientIpRange) {
    $primaryClientRange = (& az postgres flexible-server firewall-rule show `
        --name $ServerName --resource-group $resourceGroup --rule-name Client-Range `
        --query "join(',', [startIpAddress, endIpAddress])" -o tsv --only-show-errors 2>$null)
    if ($LASTEXITCODE -ne 0 -or $primaryClientRange.Trim() -ne "$clientIpRangeStart,$clientIpRangeEnd") {
        Write-Host "Allowing client range $clientIpRangeStart - $clientIpRangeEnd on the primary..."
        Invoke-NativeCommand az postgres flexible-server firewall-rule create `
            --name $ServerName --resource-group $resourceGroup `
            --rule-name Client-Range --start-ip-address $clientIpRangeStart `
            --end-ip-address $clientIpRangeEnd --only-show-errors
    } else {
        Write-Host "Primary firewall already allows client range $clientIpRangeStart - $clientIpRangeEnd."
    }
}

Write-Host 'Checking read replica...'
$existingReplica = (& az postgres flexible-server show --name $replicaName --resource-group $resourceGroup --only-show-errors -o json 2>$null | Out-String)
$replicaWasCreated = $false
if ($LASTEXITCODE -eq 0 -and $existingReplica) {
    Write-Host "Read replica '$replicaName' already exists; reusing it."
} else {
    Write-Host "Creating read replica '$replicaName' (several minutes)..."
    Invoke-NativeCommand az postgres flexible-server replica create `
        --name $replicaName --resource-group $resourceGroup `
        --source-server $ServerName --location $location `
        --only-show-errors --output none
    $replicaWasCreated = $true
}

$requiredReplicaReadyObservations = if ($replicaWasCreated) { 3 } else { 1 }
Wait-FlexibleServerReady -Name $replicaName -StableObservations $requiredReplicaReadyObservations

$replicaPublicAccess = (& az postgres flexible-server show --name $replicaName `
    --resource-group $resourceGroup --query network.publicNetworkAccess -o tsv --only-show-errors)
if ($LASTEXITCODE -ne 0) { throw "Could not read network configuration for '$replicaName'." }
if ($replicaPublicAccess -ne 'Enabled') {
    Write-Host "Enabling public network access on read replica '$replicaName'..."
    Invoke-NativeCommand az postgres flexible-server update `
        --name $replicaName --resource-group $resourceGroup `
        --public-access Enabled --only-show-errors
    Wait-FlexibleServerReady -Name $replicaName -StableObservations 3
} else {
    Write-Host "Public network access is already enabled on read replica '$replicaName'."
}
$replicaFirewallRange = (& az postgres flexible-server firewall-rule show `
    --name $replicaName --resource-group $resourceGroup --rule-name AllowScriptClient `
    --query "join(',', [startIpAddress, endIpAddress])" -o tsv --only-show-errors 2>$null)
if ($LASTEXITCODE -ne 0 -or $replicaFirewallRange.Trim() -ne "$startIpAddress,$endIpAddress") {
    Write-Host "Allowing client IP $clientIpAddress on the read replica..."
    Invoke-NativeCommand az postgres flexible-server firewall-rule create `
        --name $replicaName --resource-group $resourceGroup `
        --rule-name AllowScriptClient --start-ip-address $startIpAddress `
        --end-ip-address $endIpAddress --only-show-errors
} else {
    Write-Host "Replica firewall already allows client IP $clientIpAddress."
}
if ($hasClientIpRange) {
    $replicaClientRange = (& az postgres flexible-server firewall-rule show `
        --name $replicaName --resource-group $resourceGroup --rule-name Client-Range `
        --query "join(',', [startIpAddress, endIpAddress])" -o tsv --only-show-errors 2>$null)
    if ($LASTEXITCODE -ne 0 -or $replicaClientRange.Trim() -ne "$clientIpRangeStart,$clientIpRangeEnd") {
        Write-Host "Allowing client range $clientIpRangeStart - $clientIpRangeEnd on the read replica..."
        Invoke-NativeCommand az postgres flexible-server firewall-rule create `
            --name $replicaName --resource-group $resourceGroup `
            --rule-name Client-Range --start-ip-address $clientIpRangeStart `
            --end-ip-address $clientIpRangeEnd --only-show-errors
    } else {
        Write-Host "Replica firewall already allows client range $clientIpRangeStart - $clientIpRangeEnd."
    }
}

$readOnlyEndpoint = (& az postgres flexible-server show --name $replicaName `
    --resource-group $resourceGroup --query fullyQualifiedDomainName -o tsv --only-show-errors)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($readOnlyEndpoint)) {
    throw 'Could not read the reader endpoint.'
}
$replicaConnection = "host=$readOnlyEndpoint port=5432 dbname=postgres user=$adminUser sslmode=require connect_timeout=15"
Wait-PostgresReadReplicaReady -Connection $replicaConnection

Write-Host 'Reading server endpoints...'
$readWriteEndpoint = (& az postgres flexible-server show --name $ServerName --resource-group $resourceGroup --query fullyQualifiedDomainName -o tsv)
if ($LASTEXITCODE -ne 0) { throw 'Could not read the read/write endpoint.' }
Set-EnvironmentFileValues @{
    SERVER_NAME = $ServerName
    REPLICA_NAME = $replicaName
    RW_ENDPOINT = $readWriteEndpoint
    RO_ENDPOINT = $readOnlyEndpoint
}
Write-Host 'Wrote server names and endpoints into .env:'
Write-Host "  SERVER_NAME=$ServerName"
Write-Host "  REPLICA_NAME=$replicaName"
Write-Host "  RW_ENDPOINT=$readWriteEndpoint"
Write-Host "  RO_ENDPOINT=$readOnlyEndpoint"

Write-Host "Checking database '$databaseName' through Azure Resource Manager..."
$existingDatabase = (& az postgres flexible-server db show `
    --server-name $ServerName --resource-group $resourceGroup `
    --database-name $databaseName --only-show-errors -o json 2>$null | Out-String)
$databaseExists = $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existingDatabase)
$createDatabase = -not $databaseExists
if ($databaseName -eq 'postgres') {
    Write-Host "Using the built-in 'postgres' database."
    $createDatabase = $false
} elseif ($databaseExists) {
    $recreateDatabase = if ($recreateDatabaseApproved) {
        'y'
    } else {
        Read-Host "Database '$databaseName' already exists. Drop and recreate it? ALL DATA WILL BE LOST. [y/N]"
    }
    if ($recreateDatabase -in @('y', 'Y')) {
        if ($databaseName -in @('azure_maintenance', 'azure_sys', 'template0', 'template1')) {
            throw "Database '$databaseName' is a protected Azure or PostgreSQL system database and cannot be recreated by this script."
        }

        Write-Host "Dropping database '$databaseName'..."
        Invoke-NativeCommand az postgres flexible-server db delete `
            --server-name $ServerName --resource-group $resourceGroup `
            --database-name $databaseName --yes --only-show-errors
        $createDatabase = $true
    } else {
        Write-Host "Keeping existing database '$databaseName'."
    }
}

if ($createDatabase) {
    Write-Host "Creating database '$databaseName' on primary server '$ServerName'..."
    Invoke-NativeCommand az postgres flexible-server db create `
        --server-name $ServerName --resource-group $resourceGroup `
        --database-name $databaseName --only-show-errors
    Write-Host "Database '$databaseName' is ready."
}

Write-Host @'

NEXT:
    Client firewall access is configured from CLIENT_IP_ADDRESS in .env.
Then:  .\scripts\02-load-data.ps1
'@