<#
Direct lookup of an appmodule by GUID — bypasses any filter weirdness so we can
see what's actually in the row (uniquename, statecode, ismanaged, etc.).
#>
param(
    [string] $EnvironmentUrl = 'https://<DATAVERSE_HOST>',
    [Parameter(Mandatory)] [string] $AppModuleId,
    [string] $TenantId
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

Write-Host "Direct GET appmodules($AppModuleId)..." -ForegroundColor Cyan
try {
    $r = Invoke-RestMethod -Method GET -Uri "$apiBase/appmodules($AppModuleId)" -Headers $headers
    $r | Format-List appmoduleid, uniquename, name, clienttype, navigationtype, statecode, statuscode, ismanaged, publishedon, webresourceid, descriptor, createdon, modifiedon
} catch {
    Write-Host "  GET by id failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host "`nAll appmodules (top 25, any state)..." -ForegroundColor Cyan
$r2 = Invoke-RestMethod -Method GET -Uri "$apiBase/appmodules?`$top=25&`$select=appmoduleid,uniquename,name,statecode,ismanaged" -Headers $headers
$r2.value | Format-Table appmoduleid, uniquename, name, statecode, ismanaged -AutoSize

Write-Host "`nUnpublished/all appmodulemetadata search for 'clm'..." -ForegroundColor Cyan
$r3 = Invoke-RestMethod -Method GET -Uri "$apiBase/appmodules?`$filter=contains(uniquename,'clm') or contains(name,'Credential')&`$select=appmoduleid,uniquename,name,statecode,ismanaged" -Headers $headers
$r3.value | Format-Table appmoduleid, uniquename, name, statecode, ismanaged -AutoSize
