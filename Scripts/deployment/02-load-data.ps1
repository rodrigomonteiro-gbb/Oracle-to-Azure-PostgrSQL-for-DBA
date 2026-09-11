. "$PSScriptRoot\_common.ps1"

Assert-Command 'psql'
$customers = if ($env:CUSTOMERS) { $env:CUSTOMERS } else { '50000' }
$products = if ($env:PRODUCTS) { $env:PRODUCTS } else { '1000' }
$orders = if ($env:ORDERS) { $env:ORDERS } else { '500000' }
$connection = Get-ReadWriteConnection

Write-Host 'Creating schema on the read/write endpoint...'
Invoke-NativeCommand psql $connection -v ON_ERROR_STOP=1 -f (Join-Path $RepoRoot 'sql\schema.sql')

Write-Host "Seeding data (customers=$customers products=$products orders=$orders)..."
Invoke-NativeCommand psql $connection -v ON_ERROR_STOP=1 `
    -v "customers=$customers" -v "products=$products" -v "orders=$orders" `
    -f (Join-Path $RepoRoot 'sql\seed.sql')

Write-Host 'Done. Next: .\scripts\03-read-from-replica.ps1'