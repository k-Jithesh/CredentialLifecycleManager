param(
    [Parameter(Mandatory)][string]$DiscoveryAppId,
    [string]$TenantId = '<TENANT_ID>',
    [string[]]$ExtraRedirectUris
)
$ErrorActionPreference = 'Stop'
Import-Module Az.Accounts, Az.Resources -ErrorAction Stop
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx -or $ctx.Tenant.Id -ne $TenantId) { Connect-AzAccount -TenantId $TenantId | Out-Null }

$app = Get-AzADApplication -ApplicationId $DiscoveryAppId -ErrorAction Stop

# Read current URIs
$getResp = Invoke-AzRestMethod -Method GET -Uri "https://graph.microsoft.com/v1.0/applications/$($app.Id)?`$select=web"
if ($getResp.StatusCode -ge 300) { throw "GET failed: $($getResp.StatusCode) $($getResp.Content)" }
$current = ((ConvertFrom-Json $getResp.Content).web.redirectUris) ?? @()

$defaults = @(
    'https://global.consent.azure-apim.net/redirect',
    'https://global-test.consent.azure-apim.net/redirect'
)
$merged = ($current + $defaults + $ExtraRedirectUris) | Where-Object { $_ } | Select-Object -Unique

$body = @{ web = @{ redirectUris = $merged } } | ConvertTo-Json -Depth 5
$resp = Invoke-AzRestMethod -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$($app.Id)" -Payload $body
if ($resp.StatusCode -ge 300) { throw "PATCH failed: $($resp.StatusCode) $($resp.Content)" }

Write-Host "Redirect URIs on $DiscoveryAppId:" -ForegroundColor Green
$merged | ForEach-Object { Write-Host "  $_" }
