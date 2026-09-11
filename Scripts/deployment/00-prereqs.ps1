. "$PSScriptRoot\_common.ps1"

function Add-UserPathDirectory {
    param([Parameter(Mandatory)][string] $Directory)

    $resolvedDirectory = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $userEntries = @($userPath -split ';' | Where-Object { $_ })
    if ($userEntries.TrimEnd('\') -notcontains $resolvedDirectory) {
        $newUserPath = (@($userEntries) + $resolvedDirectory) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
        Write-Host "Added to user PATH: $resolvedDirectory"
    }

    $processEntries = @($env:Path -split ';' | Where-Object { $_ })
    if ($processEntries.TrimEnd('\') -notcontains $resolvedDirectory) {
        $env:Path = "$($env:Path);$resolvedDirectory"
    }
}

function Find-ExecutablePath {
    param(
        [Parameter(Mandatory)][string] $Name,
        [string[]] $CandidatePaths = @()
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    foreach ($candidatePath in $CandidatePaths) {
        if ($candidatePath -and (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            return $candidatePath
        }
    }
    return $null
}

function Install-WinGetPackage {
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $DisplayName
    )

    Assert-Command 'winget'
    Write-Host "Installing $DisplayName ($Id)..."
    Invoke-NativeCommand winget install --id $Id --exact --silent `
        --accept-package-agreements --accept-source-agreements `
        --disable-interactivity
}

function Ensure-Executable {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $DisplayName,
        [Parameter(Mandatory)][string] $PackageId,
        [string[]] $CandidatePaths = @()
    )

    $executablePath = Find-ExecutablePath -Name $Name -CandidatePaths $CandidatePaths
    if (-not $executablePath) {
        Install-WinGetPackage -Id $PackageId -DisplayName $DisplayName
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $env:Path = "$machinePath;$userPath"
        $executablePath = Find-ExecutablePath -Name $Name -CandidatePaths $CandidatePaths
    }
    if (-not $executablePath) {
        throw "$DisplayName was installed but '$Name' could not be located. Start a new terminal and rerun this script."
    }

    Add-UserPathDirectory -Directory (Split-Path -Parent $executablePath)
    Write-Host "${DisplayName}: $executablePath"
    return $executablePath
}

function Ensure-VsCodeExtension {
    param([Parameter(Mandatory)][string] $Id)

    $installedExtensions = @(& code --list-extensions 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not list installed VS Code extensions.'
    }
    if ($installedExtensions -contains $Id) {
        Write-Host "VS Code extension already installed: $Id"
        return
    }

    Write-Host "Installing VS Code extension: $Id"
    Invoke-NativeCommand code --install-extension $Id --force
}

$postgreSqlBinDirectories = @()
$postgreSqlRoot = Join-Path $env:ProgramFiles 'PostgreSQL'
if (Test-Path -LiteralPath $postgreSqlRoot -PathType Container) {
    $postgreSqlBinDirectories = @(Get-ChildItem -LiteralPath $postgreSqlRoot -Directory |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'bin' })
}

$azureCliPath = Ensure-Executable -Name 'az' -DisplayName 'Azure CLI' `
    -PackageId 'Microsoft.AzureCLI' -CandidatePaths @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft SDKs\Azure\CLI2\wbin\az.cmd'),
        (Join-Path $env:ProgramFiles 'Microsoft SDKs\Azure\CLI2\wbin\az.cmd')
    )
$vsCodePath = Ensure-Executable -Name 'code' -DisplayName 'Visual Studio Code' `
    -PackageId 'Microsoft.VisualStudioCode' -CandidatePaths @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd')
    )
$pgBenchPath = Ensure-Executable -Name 'pgbench' -DisplayName 'pgbench' `
    -PackageId 'PostgreSQL.PostgreSQL.17' -CandidatePaths @(
        @($postgreSqlBinDirectories | ForEach-Object { Join-Path $_ 'pgbench.exe' })
        (Join-Path $env:ProgramFiles 'pgAdmin 4\pgbench.exe')
        (Join-Path $env:ProgramFiles 'pgAdmin 4\runtime\pgbench.exe')
    )
$psqlPath = Ensure-Executable -Name 'psql' -DisplayName 'psql' `
    -PackageId 'PostgreSQL.PostgreSQL.17' -CandidatePaths @(
        @($postgreSqlBinDirectories | ForEach-Object { Join-Path $_ 'psql.exe' })
        (Join-Path $env:ProgramFiles 'pgAdmin 4\runtime\psql.exe')
    )
$pgAdminPath = Ensure-Executable -Name 'pgAdmin4' -DisplayName 'pgAdmin 4' `
    -PackageId 'PostgreSQL.pgAdmin' -CandidatePaths @(
        (Join-Path $env:ProgramFiles 'pgAdmin 4\runtime\pgAdmin4.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\pgAdmin 4\runtime\pgAdmin4.exe')
    )

Ensure-VsCodeExtension 'ms-ossdata.vscode-pgsql'
Ensure-VsCodeExtension 'bierner.markdown-mermaid'

Write-Host '== Azure CLI =='
Write-Host "Extension directory: $($env:AZURE_EXTENSION_DIR)"
Invoke-NativeCommand az version -o table

Write-Host "`n== Subscription =="
Set-AzureSubscription

Write-Host "`n== Resource provider registration =="
$providerNamespace = 'Microsoft.DBforPostgreSQL'
$state = (& az provider show --namespace $providerNamespace --query registrationState -o tsv 2>$null)
if ($LASTEXITCODE -ne 0) {
    $state = 'NotRegistered'
}
if ($state -eq 'Registered') {
    Write-Host "$providerNamespace`: Registered"
} else {
    Write-Host "Registering $providerNamespace (current: $state)..."
    $registrationError = (& az provider register --namespace $providerNamespace 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        if ($registrationError -match 'AuthorizationFailed') {
            [Console]::Error.WriteLine(@"

ERROR: your account can't register resource providers on this subscription.
Fix one of these, then re-run:
  - set SUBSCRIPTION in .env to a subscription where you have rights, OR
  - ask a subscription Owner to run:
      az provider register --namespace $providerNamespace
"@)
            exit 1
        }
        throw $registrationError.Trim()
    }

    Write-Host -NoNewline 'Waiting for registration'
    foreach ($attempt in 1..30) {
        $state = (& az provider show --namespace $providerNamespace --query registrationState -o tsv 2>$null)
        if ($LASTEXITCODE -ne 0) {
            $state = 'Unknown'
        }
        if ($state -eq 'Registered') {
            break
        }
        Write-Host -NoNewline '.'
        Start-Sleep -Seconds 10
    }
    Write-Host "`n$providerNamespace`: $state"
}

if ($state -ne 'Registered') {
    throw 'Not registered yet; re-run in a minute.'
}
Write-Host 'Prereqs OK.'