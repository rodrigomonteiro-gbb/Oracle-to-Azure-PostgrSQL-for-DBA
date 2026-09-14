param(
    [string]$Server = 'srv-workshop-pto-pgsql.postgres.database.azure.com',
    [int]$Port = 5432,
    [string]$Database = 'adventureworks',
    [string]$User = 'postgres',
    [string]$PsqlExe = 'C:\Program Files\pgAdmin 4\runtime\psql.exe'
)

$ErrorActionPreference = 'Stop'
$env:PGSSLMODE = 'require'
$SqlFile = Join-Path $PSScriptRoot 'DBA_VacuumAnalysis.sql'
$PasswordSetByScript = $false

if (-not (Test-Path -LiteralPath $PsqlExe)) {
    $PsqlExe = (Get-Command psql.exe -ErrorAction Stop).Source
}

try {
    if (-not $env:PGPASSWORD) {
        $env:PGPASSWORD = Read-Host "Password for $User" -AsSecureString |
            ConvertFrom-SecureString -AsPlainText
        $PasswordSetByScript = $true
    }

    & $PsqlExe --host=$Server --port=$Port --username=$User --dbname=$Database `
        --no-password --set=ON_ERROR_STOP=1 --file=$SqlFile

    if ($LASTEXITCODE -ne 0) {
        throw "DBA_VacuumAnalysis.sql failed with psql exit code $LASTEXITCODE."
    }
} finally {
    if ($PasswordSetByScript) {
        Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    }
}
