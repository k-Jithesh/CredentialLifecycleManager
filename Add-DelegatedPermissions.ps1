<#
.SYNOPSIS
    Adds delegated Microsoft Graph + Azure Service Management permissions to the CLM Discovery app
    so the Power Platform custom connectors (which use delegated tokens) can authorize.

.PARAMETER DiscoveryAppId
    The Discovery app's client/AppId.

.PARAMETER TenantId
    AAD tenant id. Defaults to the CLM tenant.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DiscoveryAppId,
    [string]$TenantId = '<TENANT_ID>'
)
$ErrorActionPreference = 'Stop'

Import-Module Az.Accounts -ErrorAction Stop
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx -or $ctx.Tenant.Id -ne $TenantId) { Connect-AzAccount -TenantId $TenantId | Out-Null }

# Well-known resource AppIds
$graphAppId = '00000003-0000-0000-c000-000000000000'  # Microsoft Graph
$armAppId   = '797f4846-ba00-4fd7-ba43-dac1f8f63013'  # Azure Service Management

function Get-Sp {
    param([string]$AppId)
    $r = Invoke-AzRestMethod -Method GET -Uri ("https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$AppId'&`$select=id,appId,displayName,appRoles,oauth2PermissionScopes")
    if ($r.StatusCode -ne 200) { throw "Graph SP query failed for $AppId : $($r.StatusCode) $($r.Content)" }
    return (ConvertFrom-Json $r.Content).value | Select-Object -First 1
}
function Scope-Id { param($sp, [string]$value) ($sp.oauth2PermissionScopes | Where-Object { $_.value -eq $value } | Select-Object -First 1).id }
function Role-Id  { param($sp, [string]$value) ($sp.appRoles               | Where-Object { $_.value -eq $value } | Select-Object -First 1).id }

$graphSp = Get-Sp $graphAppId
$armSp   = Get-Sp $armAppId

$appReadDelegatedId = Scope-Id $graphSp 'Application.Read.All'
$dirReadDelegatedId = Scope-Id $graphSp 'Directory.Read.All'
$armUserImpId       = Scope-Id $armSp   'user_impersonation'

$appReadAppId = Role-Id $graphSp 'Application.Read.All'
$dirReadAppId = Role-Id $graphSp 'Directory.Read.All'

if (-not ($appReadDelegatedId -and $dirReadDelegatedId -and $armUserImpId)) {
    throw "Could not resolve one or more delegated scope ids."
}

# Get current app + appObjectId
$app = Get-AzADApplication -ApplicationId $DiscoveryAppId -ErrorAction Stop

# Build the union: app-only (Role) + delegated (Scope)
$requiredResourceAccess = @(
    @{
        resourceAppId  = $graphAppId
        resourceAccess = @(
            @{ id = $appReadAppId;      type = 'Role' }
            @{ id = $dirReadAppId;      type = 'Role' }
            @{ id = $appReadDelegatedId; type = 'Scope' }
            @{ id = $dirReadDelegatedId; type = 'Scope' }
        )
    },
    @{
        resourceAppId  = $armAppId
        resourceAccess = @(
            @{ id = $armUserImpId; type = 'Scope' }
        )
    }
)

$body = @{ requiredResourceAccess = $requiredResourceAccess } | ConvertTo-Json -Depth 10
$resp = Invoke-AzRestMethod -Method PATCH `
    -Uri "https://graph.microsoft.com/v1.0/applications/$($app.Id)" -Payload $body
if ($resp.StatusCode -ge 300) { throw "PATCH failed: $($resp.StatusCode) $($resp.Content)" }

$consentUrl = "https://login.microsoftonline.com/$TenantId/adminconsent?client_id=$DiscoveryAppId"

Write-Host "Delegated + application permissions configured on $DiscoveryAppId" -ForegroundColor Green
Write-Host ""
Write-Host "Open the admin-consent URL and approve all permissions:" -ForegroundColor Yellow
Write-Host "  $consentUrl"
Write-Host ""
Write-Host "After consent, delete + recreate the connection in both connectors (Test tab) so the new scopes are requested."
