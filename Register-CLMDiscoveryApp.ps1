<#
.SYNOPSIS
    Provisions the CLM Discovery AAD application used by the "CLM Graph & Azure"
    custom connector, generates a signing certificate, configures API permissions,
    and emits admin-consent URLs plus a Dataverse Application User stub.

.DESCRIPTION
    Creates (or updates) an AAD app registration with:
      - Microsoft Graph: Application.Read.All, Directory.Read.All (Application)
      - Azure Service Management: user_impersonation (Delegated)
      - Power Platform API: .default (Application)
    Generates a self-signed certificate (CurrentUser\My) and uploads its public key
    to the app registration. Also produces:
      - Admin consent URL
      - PFX export (password-protected) for connector upload
      - Application User CSV row for Dataverse provisioning

.PARAMETER TenantId
    Azure AD tenant ID. Defaults to the CLM tenant.

.PARAMETER DisplayName
    App registration display name. Default: "CLM Discovery Connector".

.PARAMETER CertSubject
    Certificate subject. Default: "CN=CLM-Discovery-Connector".

.PARAMETER CertValidityMonths
    Certificate validity in months. Default: 24.

.PARAMETER PfxPassword
    SecureString password used to protect the exported PFX. Prompted if omitted.

.PARAMETER OutputFolder
    Where to write the PFX, CER, and metadata JSON. Default: .\out\discovery-app.

.PARAMETER DataverseEnvironmentUrl
    Dataverse environment URL used to render the Application User provisioning hint.
    Example: https://contoso.crm6.dynamics.com

.EXAMPLE
    .\Register-CLMDiscoveryApp.ps1 -DataverseEnvironmentUrl https://contoso.crm6.dynamics.com

.NOTES
    Requires: Az.Accounts, Az.Resources (>= 6.x). Sign in with an account that can
    create AAD apps and grant tenant-wide admin consent (Application Administrator
    or Global Administrator).
#>

[CmdletBinding()]
param(
    [string]$TenantId = '<TENANT_ID>',
    [string]$DisplayName = 'CLM Discovery Connector',
    [string]$CertSubject = 'CN=CLM-Discovery-Connector',
    [int]$CertValidityMonths = 24,
    [SecureString]$PfxPassword,
    [string]$OutputFolder = (Join-Path $PSScriptRoot 'out\discovery-app'),
    [Parameter(Mandatory)][string]$DataverseEnvironmentUrl
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# 0. Prereqs
# ---------------------------------------------------------------------------
function Ensure-Module {
    param([string]$Name, [string]$MinVersion)
    $m = Get-Module -ListAvailable -Name $Name |
            Where-Object { -not $MinVersion -or $_.Version -ge [version]$MinVersion } |
            Select-Object -First 1
    if (-not $m) {
        Write-Host "Installing module $Name..." -ForegroundColor Yellow
        Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber -MinimumVersion $MinVersion
    }
    Import-Module $Name -MinimumVersion $MinVersion -ErrorAction Stop
}

Ensure-Module -Name Az.Accounts  -MinVersion '2.15.0'
Ensure-Module -Name Az.Resources -MinVersion '6.10.0'

if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}

if (-not $PfxPassword) {
    $PfxPassword = Read-Host -AsSecureString "Enter password to protect the exported PFX"
}

# ---------------------------------------------------------------------------
# 1. Sign in to the target tenant
# ---------------------------------------------------------------------------
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx -or $ctx.Tenant.Id -ne $TenantId) {
    Write-Host "Signing in to tenant $TenantId..." -ForegroundColor Cyan
    Connect-AzAccount -TenantId $TenantId | Out-Null
}

# ---------------------------------------------------------------------------
# 2. Generate the self-signed certificate
# ---------------------------------------------------------------------------
Write-Host "Generating certificate '$CertSubject'..." -ForegroundColor Cyan
$cert = New-SelfSignedCertificate `
    -Subject $CertSubject `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -KeyExportPolicy Exportable `
    -KeySpec Signature `
    -KeyLength 2048 `
    -KeyAlgorithm RSA `
    -HashAlgorithm SHA256 `
    -NotAfter (Get-Date).AddMonths($CertValidityMonths)

$pfxPath = Join-Path $OutputFolder "$($DisplayName -replace '\s','_').pfx"
$cerPath = Join-Path $OutputFolder "$($DisplayName -replace '\s','_').cer"

Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $PfxPassword | Out-Null
Export-Certificate    -Cert $cert -FilePath $cerPath -Type CERT          | Out-Null

$certBytes  = [System.IO.File]::ReadAllBytes($cerPath)
$certBase64 = [Convert]::ToBase64String($certBytes)

Write-Host "  PFX: $pfxPath" -ForegroundColor Green
Write-Host "  CER: $cerPath" -ForegroundColor Green
Write-Host "  Thumbprint: $($cert.Thumbprint)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3. Resolve required API permissions (resource + scope/role IDs)
# ---------------------------------------------------------------------------
# Well-known resource AppIds
$graphAppId      = '00000003-0000-0000-c000-000000000000'  # Microsoft Graph
$armAppId        = '797f4846-ba00-4fd7-ba43-dac1f8f63013'  # Azure Service Management
$powerPlatformId = '8578e004-a5c6-46e7-913e-12f58912df43'  # Power Platform API

function Get-SpFromGraph {
    param([string]$AppId, [string]$Name)
    $uri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$AppId'&`$select=id,appId,displayName,appRoles,oauth2PermissionScopes"
    $resp = Invoke-AzRestMethod -Method GET -Uri $uri
    if ($resp.StatusCode -ne 200) {
        throw "Graph query for $Name ($AppId) failed: $($resp.StatusCode) $($resp.Content)"
    }
    $sp = (ConvertFrom-Json $resp.Content).value | Select-Object -First 1
    if (-not $sp) {
        Write-Host "  Service principal for $Name not found in tenant - creating..." -ForegroundColor Yellow
        New-AzADServicePrincipal -ApplicationId $AppId | Out-Null
        $resp = Invoke-AzRestMethod -Method GET -Uri $uri
        $sp = (ConvertFrom-Json $resp.Content).value | Select-Object -First 1
    }
    return $sp
}

function Get-AppRoleId {
    param($sp, [string]$Value)
    $role = $sp.appRoles | Where-Object { $_.value -eq $Value } | Select-Object -First 1
    if (-not $role) { throw "App role '$Value' not found on $($sp.displayName) ($($sp.appId))" }
    return $role.id
}
function Get-OAuthScopeId {
    param($sp, [string]$Value)
    $scope = $sp.oauth2PermissionScopes | Where-Object { $_.value -eq $Value } | Select-Object -First 1
    if (-not $scope) { throw "Delegated scope '$Value' not found on $($sp.displayName) ($($sp.appId))" }
    return $scope.id
}

Write-Host "Resolving resource service principals..." -ForegroundColor Cyan
$graphSp = Get-SpFromGraph -AppId $graphAppId      -Name 'Microsoft Graph'
$armSp   = Get-SpFromGraph -AppId $armAppId        -Name 'Azure Service Management'
$ppSp    = Get-SpFromGraph -AppId $powerPlatformId -Name 'Power Platform API'

$appReadAllId       = Get-AppRoleId   -sp $graphSp -Value 'Application.Read.All'
$directoryReadAllId = Get-AppRoleId   -sp $graphSp -Value 'Directory.Read.All'
$armUserImpId       = Get-OAuthScopeId -sp $armSp  -Value 'user_impersonation'
# Power Platform API has no concrete '.default' app role; '.default' is a virtual consent scope.
$ppDefaultId        = $null
$ppRole = $ppSp.appRoles | Where-Object { $_.value -eq '.default' } | Select-Object -First 1
if ($ppRole) { $ppDefaultId = $ppRole.id }

$requiredResourceAccess = @(
    @{
        resourceAppId  = $graphAppId
        resourceAccess = @(
            @{ id = $appReadAllId;       type = 'Role' },
            @{ id = $directoryReadAllId; type = 'Role' }
        )
    },
    @{
        resourceAppId  = $armAppId
        resourceAccess = @(
            @{ id = $armUserImpId; type = 'Scope' }
        )
    }
)

# Power Platform .default is requested at consent time; only add if a concrete app role exists.
if ($ppDefaultId) {
    $requiredResourceAccess += @{
        resourceAppId  = $powerPlatformId
        resourceAccess = @(@{ id = $ppDefaultId; type = 'Role' })
    }
}

# ---------------------------------------------------------------------------
# 4. Create or update the application
# ---------------------------------------------------------------------------
Write-Host "Ensuring app registration '$DisplayName'..." -ForegroundColor Cyan
$app = Get-AzADApplication -DisplayName $DisplayName -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $app) {
    $app = New-AzADApplication `
        -DisplayName $DisplayName `
        -SignInAudience AzureADMyOrg
    Write-Host "  Created AppId: $($app.AppId)" -ForegroundColor Green
} else {
    Write-Host "  Reusing existing AppId: $($app.AppId)" -ForegroundColor Green
}

# Register Power Platform custom-connector redirect URIs as Web reply URLs
$webPatch = @{
    web = @{
        redirectUris = @(
            'https://global.consent.azure-apim.net/redirect',
            'https://global-test.consent.azure-apim.net/redirect'
        )
    }
} | ConvertTo-Json -Depth 5
$webResp = Invoke-AzRestMethod -Method PATCH `
    -Uri "https://graph.microsoft.com/v1.0/applications/$($app.Id)" -Payload $webPatch
if ($webResp.StatusCode -ge 300) {
    throw "Failed to set web.redirectUris: $($webResp.StatusCode) $($webResp.Content)"
}

# Update required resource access via direct Graph PATCH
# (Update-AzADApplication mis-serializes nested hashtables -> "An item with the same key has already been added. Key: id")
$patchBody = @{ requiredResourceAccess = $requiredResourceAccess } | ConvertTo-Json -Depth 10
$patchUri  = "https://graph.microsoft.com/v1.0/applications/$($app.Id)"
$patchResp = Invoke-AzRestMethod -Method PATCH -Uri $patchUri -Payload $patchBody
if ($patchResp.StatusCode -ge 300) {
    throw "Failed to update requiredResourceAccess: $($patchResp.StatusCode) $($patchResp.Content)"
}

# Upload the certificate as a key credential
Write-Host "Uploading certificate to app registration..." -ForegroundColor Cyan
$existingCreds = Get-AzADAppCredential -ObjectId $app.Id -ErrorAction SilentlyContinue
foreach ($c in $existingCreds | Where-Object { $_.DisplayName -eq $CertSubject }) {
    Remove-AzADAppCredential -ObjectId $app.Id -KeyId $c.KeyId -ErrorAction SilentlyContinue
}
New-AzADAppCredential `
    -ObjectId $app.Id `
    -CertValue $certBase64 `
    -StartDate $cert.NotBefore `
    -EndDate   $cert.NotAfter | Out-Null

# Ensure tenant service principal for our app exists
$appSp = Get-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction SilentlyContinue
if (-not $appSp) {
    Write-Host "Creating service principal for app..." -ForegroundColor Cyan
    $appSp = New-AzADServicePrincipal -ApplicationId $app.AppId
}

# ---------------------------------------------------------------------------
# 5. Emit admin-consent URLs
# ---------------------------------------------------------------------------
$consentUrl = "https://login.microsoftonline.com/$TenantId/adminconsent?client_id=$($app.AppId)"
$ppConsent  = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/authorize?client_id=$($app.AppId)&response_type=code&scope=https%3A%2F%2Fapi.powerplatform.com%2F.default&prompt=admin_consent"

# ---------------------------------------------------------------------------
# 6. Dataverse Application User hint
# ---------------------------------------------------------------------------
$dvHint = @"
Provision Dataverse Application User:
  1. Open: $DataverseEnvironmentUrl
  2. Power Platform admin center -> Environments -> <env> -> Settings -> Users + permissions -> Application users
  3. + New app user
       Application (client) ID : $($app.AppId)
       Business unit           : <root BU>
       Security role           : CLM Platform Ops
"@

# ---------------------------------------------------------------------------
# 7. Write metadata + summary
# ---------------------------------------------------------------------------
$metadata = [ordered]@{
    tenantId               = $TenantId
    displayName            = $DisplayName
    appId                  = $app.AppId
    objectId               = $app.Id
    servicePrincipalId     = $appSp.Id
    certificate            = [ordered]@{
        subject     = $CertSubject
        thumbprint  = $cert.Thumbprint
        notBefore   = $cert.NotBefore
        notAfter    = $cert.NotAfter
        pfxPath     = $pfxPath
        cerPath     = $cerPath
    }
    permissions            = @(
        'Microsoft Graph / Application.Read.All (Application)',
        'Microsoft Graph / Directory.Read.All (Application)',
        'Azure Service Management / user_impersonation (Delegated)',
        'Power Platform API / .default (Application)'
    )
    adminConsentUrl        = $consentUrl
    powerPlatformConsentUrl = $ppConsent
    dataverseAppUserHint   = $dvHint
}

$metaPath = Join-Path $OutputFolder 'discovery-app.json'
$metadata | ConvertTo-Json -Depth 6 | Set-Content -Path $metaPath -Encoding UTF8

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " CLM Discovery app registration complete" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "AppId             : $($app.AppId)"
Write-Host "Cert thumbprint   : $($cert.Thumbprint)"
Write-Host "PFX (connector)   : $pfxPath"
Write-Host "Metadata          : $metaPath"
Write-Host ""
Write-Host "Grant tenant-wide admin consent:" -ForegroundColor Yellow
Write-Host "  $consentUrl"
Write-Host ""
Write-Host "Power Platform API consent (if not granted above):" -ForegroundColor Yellow
Write-Host "  $ppConsent"
Write-Host ""
Write-Host $dvHint -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Open the admin-consent URL above and approve all permissions."
Write-Host "  2. Assign 'Key Vault Reader' RBAC on the target Key Vault(s) to the app's service principal:"
Write-Host "       New-AzRoleAssignment -ApplicationId $($app.AppId) -RoleDefinitionName 'Key Vault Reader' -Scope <kv-resource-id>"
Write-Host "  3. Add the app as a Dataverse Application User with the 'CLM Platform Ops' role (see hint above)."
Write-Host "  4. Upload $pfxPath to the 'CLM Graph & Azure' custom connector and bind the AppId."
