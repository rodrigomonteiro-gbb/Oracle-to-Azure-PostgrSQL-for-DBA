. "$PSScriptRoot\_common.ps1"

Assert-Command 'az'
$resourceGroup = Assert-EnvironmentVariable 'RESOURCE_GROUP'
$serverName = Get-PrimaryServerName
$replicaName = Get-ReplicaServerName

$answer = Read-Host "Delete primary '$serverName', replica '$replicaName', and resource group '$resourceGroup'? [y/N]"
if ($answer -notin @('y', 'Y')) {
    Write-Host 'Aborted.'
    exit 0
}

Write-Host 'Deleting resource group (async)...'
Invoke-NativeCommand az group delete --name $resourceGroup --yes --no-wait

Write-Host 'Teardown started. The resource group will finish deleting in the background.'