param(
    [string] $ResourceGroup,
    [Alias('ClusterName')]
    [string] $ServerName,
    [string] $ReplicaName
)

. "$PSScriptRoot\_common.ps1"

Assert-Command 'az'
if (-not $ResourceGroup) { $ResourceGroup = Assert-EnvironmentVariable 'RESOURCE_GROUP' }
if (-not $ServerName) { $ServerName = Get-PrimaryServerName }
if (-not $ReplicaName) { $ReplicaName = Get-ReplicaServerName }

Set-AzureSubscription
Write-Host "Primary: $ServerName  /  Replica: $ReplicaName  /  Resource group: $ResourceGroup"
Write-Host '(override with: .\scripts\bootstrap-env.ps1 <resource-group> <primary-name> <replica-name>)'
Write-Host

$location = (& az postgres flexible-server show --name $ServerName --resource-group $ResourceGroup --query location -o tsv)
if ($LASTEXITCODE -ne 0) { throw 'Could not read the primary server location.' }
$readWriteEndpoint = (& az postgres flexible-server show --name $ServerName --resource-group $ResourceGroup --query fullyQualifiedDomainName -o tsv)
if ($LASTEXITCODE -ne 0) { throw 'Could not read the read/write endpoint.' }
$readOnlyEndpoint = (& az postgres flexible-server show --name $ReplicaName --resource-group $ResourceGroup --query fullyQualifiedDomainName -o tsv)
if ($LASTEXITCODE -ne 0) { throw 'Could not read the replica endpoint.' }
$pgVersion = (& az postgres flexible-server show --name $ServerName --resource-group $ResourceGroup --query version -o tsv)
if ($LASTEXITCODE -ne 0) { throw 'Could not read the PostgreSQL version.' }
if (-not $readWriteEndpoint) {
    throw 'Could not read endpoints. Check the subscription, resource group, and server names.'
}

Set-EnvironmentFileValues @{
    RESOURCE_GROUP = $ResourceGroup
    LOCATION = $location
    SERVER_NAME = $ServerName
    REPLICA_NAME = $ReplicaName
    PG_VERSION = $pgVersion
    RW_ENDPOINT = $readWriteEndpoint
    RO_ENDPOINT = $readOnlyEndpoint
}

Write-Host 'Refreshed .env:'
Write-Host "RESOURCE_GROUP=$ResourceGroup"
Write-Host "LOCATION=$location"
Write-Host "SERVER_NAME=$ServerName"
Write-Host "REPLICA_NAME=$ReplicaName"
Write-Host "RW_ENDPOINT=$readWriteEndpoint"
Write-Host "RO_ENDPOINT=$readOnlyEndpoint"
Write-Host
Write-Host "Test it: psql `"$(Get-ReadWriteConnection)`" -c 'select version();'"