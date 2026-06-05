<#
.SYNOPSIS
    Deploys the CLM custom connector pair (Graph + ARM) to a Power Platform environment
    using paconn.

.DESCRIPTION
    Power Platform custom connectors are single-host. CLM splits into:
      - CLM Graph Discovery   (host: graph.microsoft.com)
      - CLM Azure Discovery   (host: management.azure.com)
    Both connectors share the same Discovery AAD app + certificate, just different OAuth scopes.

    Wraps paconn create / paconn update. paconn requires --secret even for
    aadcertificate connectors; this script auto-creates a 24h client secret on the
    Discovery app for the duration of deploy and removes it afterwards.

.PARAMETER DiscoveryAppId
    Client/AppId of the CLM Discovery app (from Register-CLMDiscoveryApp.ps1).

.PARAMETER TenantId
    AAD tenant id. Defaults to the CLM tenant.

.PARAMETER EnvironmentId
    Target Power Platform environment GUID.

.PARAMETER GraphConnectorId
    Optional. Existing connector id to update (Graph); omit on first create.

.PARAMETER ArmConnectorId
    Optional. Existing connector id to update (ARM); omit on first create.

.PARAMETER Only
    "graph", "arm", or "both" (default).

.PARAMETER ConnectorFolder
    Folder holding the swagger / apiProperties / settings files. Default: .\connector

.PARAMETER IconPath
    Optional 1x1+ PNG used as the connector tile icon.

.PARAMETER ClientSecret
    If supplied, used directly instead of auto-generating a temp secret.

.PARAMETER KeepTempSecret
    Keep the temp client secret after deploy (default: removed).

.EXAMPLE
    .\Deploy-CLMConnector.ps1 -DiscoveryAppId <appId> -EnvironmentId <envGuid>
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DiscoveryAppId,
    [string]$TenantId        = '<TENANT_ID>',
    [Parameter(Mandatory)][string]$EnvironmentId,
    [string]$GraphConnectorId,
    [string]$ArmConnectorId,
    [ValidateSet('graph','arm','both')][string]$Only = 'both',
    [string]$ConnectorFolder = (Join-Path $PSScriptRoot 'connector'),
    [string]$IconPath,
    [string]$ClientSecret
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------- 1. Resolve paconn ----------
function Resolve-Paconn {
    $cmd = Get-Command paconn -ErrorAction SilentlyContinue
    if ($cmd) { return @{ Exe = $cmd.Source; Args = @() } }

    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
    if (-not $py) { throw "Python 3.8+ is required. Install from https://www.python.org/ and tick 'Add to PATH'." }

    & $py.Source -c "import paconn" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Installing paconn..." -ForegroundColor Yellow
        & $py.Source -m pip install --user --upgrade paconn
        if ($LASTEXITCODE -ne 0) { throw "pip install paconn failed." }
    }

    $cmd = Get-Command paconn -ErrorAction SilentlyContinue
    if ($cmd) { return @{ Exe = $cmd.Source; Args = @() } }

    $userBase  = (& $py.Source -m site --user-base).Trim()
    $candidate = Join-Path $userBase 'Scripts\paconn.exe'
    if (Test-Path $candidate) {
        $env:PATH = (Split-Path $candidate) + ';' + $env:PATH
        return @{ Exe = $candidate; Args = @() }
    }
    return @{ Exe = $py.Source; Args = @('-m','paconn') }
}
$paconn = Resolve-Paconn
function Invoke-Paconn { & $paconn.Exe @($paconn.Args + $args) }

# ---------- 2. Patch helper ----------
function Patch-Files {
    param([string]$ApiPropsPath, [string]$SettingsPath, [string]$ConnectorIdValue)
    $apiProps = Get-Content $ApiPropsPath -Raw | ConvertFrom-Json
    $apiProps.properties.connectionParameters.token.oAuthSettings.clientId = $DiscoveryAppId
    $apiProps.properties.connectionParameters.token.oAuthSettings.customParameters.tenantId.value = $TenantId
    $apiProps | ConvertTo-Json -Depth 20 | Set-Content -Path $ApiPropsPath -Encoding UTF8

    $settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
    $settings.environment = $EnvironmentId
    if ($ConnectorIdValue) { $settings.connectorId = $ConnectorIdValue }
    $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $SettingsPath -Encoding UTF8
}

if ($IconPath -and (Test-Path $IconPath)) {
    Copy-Item $IconPath (Join-Path $ConnectorFolder 'icon.png') -Force
}

# ---------- 3. Patch both pairs ----------
if ($Only -in 'graph','both') {
    Patch-Files `
        -ApiPropsPath (Join-Path $ConnectorFolder 'apiProperties.graph.json') `
        -SettingsPath (Join-Path $ConnectorFolder 'settings.graph.json') `
        -ConnectorIdValue $GraphConnectorId
}
if ($Only -in 'arm','both') {
    Patch-Files `
        -ApiPropsPath (Join-Path $ConnectorFolder 'apiProperties.arm.json') `
        -SettingsPath (Join-Path $ConnectorFolder 'settings.arm.json') `
        -ConnectorIdValue $ArmConnectorId
}

# ---------- 4. Client secret for paconn (also used by the connector at runtime) ----------
# With identityProvider:"aad", the secret passed to paconn --secret is stored as the
# connector's OAuth client secret and is required for every new connection. Keep it.
$generatedSecretKeyId = $null
$generatedSecretExpiry = $null
if (-not $ClientSecret) {
    Write-Host "Creating long-lived client secret on Discovery app (used by the connector at runtime)..." -ForegroundColor Yellow
    foreach ($mod in @('Az.Accounts','Az.Resources')) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            Install-Module -Name $mod -Scope CurrentUser -Force -AllowClobber | Out-Null
        }
        Import-Module $mod -ErrorAction Stop
    }
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx -or $ctx.Tenant.Id -ne $TenantId) {
        Connect-AzAccount -TenantId $TenantId | Out-Null
    }
    $appObj = Get-AzADApplication -ApplicationId $DiscoveryAppId -ErrorAction Stop
    $expiry = (Get-Date).AddMonths(6)
    $cred   = New-AzADAppCredential -ObjectId $appObj.Id -StartDate (Get-Date) -EndDate $expiry
    $ClientSecret         = $cred.SecretText
    $generatedSecretKeyId = $cred.KeyId
    $generatedSecretExpiry = $expiry
    if (-not $ClientSecret) { throw "Failed to retrieve secret text. Pass -ClientSecret manually." }
    Write-Host "  Secret created (KeyId $generatedSecretKeyId, expires $($expiry.ToString('yyyy-MM-dd')))." -ForegroundColor Green
}

# ---------- 5. Deploy ----------
function Deploy-One {
    param([string]$SettingsFile, [string]$ConnectorIdValue, [string]$Label)
    Write-Host ""
    Write-Host "---- $Label ----" -ForegroundColor Cyan
    if ($ConnectorIdValue) {
        Write-Host "Updating connector $ConnectorIdValue..." -ForegroundColor Cyan
        Invoke-Paconn update --settings $SettingsFile --secret $ClientSecret
    } else {
        Write-Host "Creating connector..." -ForegroundColor Cyan
        Invoke-Paconn create --settings $SettingsFile --secret $ClientSecret
    }
}

Push-Location $ConnectorFolder
try {
    Invoke-Paconn login
    if ($Only -in 'graph','both') { Deploy-One -SettingsFile 'settings.graph.json' -ConnectorIdValue $GraphConnectorId -Label 'CLM Graph Discovery' }
    if ($Only -in 'arm','both')   { Deploy-One -SettingsFile 'settings.arm.json'   -ConnectorIdValue $ArmConnectorId   -Label 'CLM Azure Discovery' }
}
finally {
    Pop-Location
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " Connector(s) deployed" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
if ($generatedSecretKeyId) {
    Write-Host ""
    Write-Host "Client secret created on Discovery app (used by the connector at runtime):" -ForegroundColor Yellow
    Write-Host "  KeyId  : $generatedSecretKeyId"
    Write-Host "  Expiry : $($generatedSecretExpiry.ToString('yyyy-MM-dd'))"
    Write-Host "  Rotate before expiry via -ClientSecret <new> and re-run with -GraphConnectorId / -ArmConnectorId."
}
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Open https://make.powerautomate.com -> Data -> Custom connectors."
Write-Host "  2. For each connector: Test -> + New connection -> sign in with a service account that has admin-consented permissions."
Write-Host "  3. Validate: Graph 'ListApplications' and ARM 'ListSubscriptions'."
Write-Host "  4. Save the connector ids printed above for future updates (-GraphConnectorId / -ArmConnectorId)."
Write-Host ""
Write-Host "Note: Power Platform custom connectors don't support AAD certificate auth (1st-party only)." -ForegroundColor DarkGray
Write-Host "      The cert from Register-CLMDiscoveryApp.ps1 stays on the app for non-connector clients (PS, Functions, etc.)." -ForegroundColor DarkGray
