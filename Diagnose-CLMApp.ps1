<#
Diagnostic: inspect existing CLM appmodule rows and the appmodule entity definition.
Run with the same EnvironmentUrl you've been using for Deploy-CLMApp.ps1.
#>
param(
    [string] $EnvironmentUrl = 'https://<DATAVERSE_HOST>',
    [string] $TenantId,
    [string] $AccountId
)
$ErrorActionPreference = 'Stop'
Import-Module Az.Accounts -ErrorAction SilentlyContinue
$resource = $EnvironmentUrl.TrimEnd('/')
$tokenArgs = @{ ResourceUrl = $resource }
if ($TenantId) { $tokenArgs.TenantId = $TenantId }
$token = (Get-AzAccessToken @tokenArgs).Token
$headers = @{
    Authorization      = "Bearer $token"
    'OData-MaxVersion' = '4.0'
    'OData-Version'    = '4.0'
    Accept             = 'application/json'
}
$apiBase = "$resource/api/data/v9.2"

Write-Host "`n=== Existing appmodules with uniquename like 'clm%' ===" -ForegroundColor Cyan
$r = Invoke-RestMethod -Method GET -Uri "$apiBase/appmodules?`$filter=startswith(uniquename,'clm')&`$select=appmoduleid,uniquename,name,clienttype,publishedon,statecode,webresourceid" -Headers $headers
$r.value | Format-Table appmoduleid, uniquename, name, clienttype, statecode, webresourceid -AutoSize

Write-Host "`n=== Existing web resources with name 'clm_/icons/app_icon.svg' ===" -ForegroundColor Cyan
$enc = [uri]::EscapeDataString('clm_/icons/app_icon.svg')
$w = Invoke-RestMethod -Method GET -Uri "$apiBase/webresourceset?`$filter=name eq '$enc'&`$select=webresourceid,name,webresourcetype" -Headers $headers
$w.value | Format-Table webresourceid, name, webresourcetype -AutoSize

Write-Host "`n=== Solution components for CredentialLifecycleManager (appmodules only) ===" -ForegroundColor Cyan
$s = Invoke-RestMethod -Method GET -Uri "$apiBase/solutioncomponents?`$filter=componenttype eq 80&`$expand=solutionid(`$select=uniquename)" -Headers $headers
$s.value | Where-Object { $_.solutionid.uniquename -eq 'CredentialLifecycleManager' } | Format-Table objectid, componenttype -AutoSize

Write-Host "`n=== Done. Paste this output back. ===" -ForegroundColor Green
