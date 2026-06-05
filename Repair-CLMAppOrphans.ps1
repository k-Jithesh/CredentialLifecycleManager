<#
Removes orphan solutioncomponent rows that reference non-existent appmodules
in the CredentialLifecycleManager solution. Use when an earlier failed deploy
left a dangling component preventing new appmodule POSTs.
#>
param(
    [string] $EnvironmentUrl = 'https://<DATAVERSE_HOST>',
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
    'Content-Type'     = 'application/json; charset=utf-8'
}
$apiBase = "$resource/api/data/v9.2"

Write-Host "Scanning appmodule solution components in CredentialLifecycleManager..." -ForegroundColor Cyan
$comps = (Invoke-RestMethod -Method GET -Uri "$apiBase/solutioncomponents?`$filter=componenttype eq 80&`$expand=solutionid(`$select=uniquename)&`$select=solutioncomponentid,objectid" -Headers $headers).value |
    Where-Object { $_.solutionid.uniquename -eq 'CredentialLifecycleManager' }

if (-not $comps) {
    Write-Host "No appmodule components in this solution. Nothing to clean." -ForegroundColor Yellow
    return
}

foreach ($c in $comps) {
    $appExists = $true
    try {
        Invoke-RestMethod -Method GET -Uri "$apiBase/appmodules($($c.objectid))?`$select=appmoduleid" -Headers $headers | Out-Null
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 404) { $appExists = $false }
        else { throw }
    }

    if ($appExists) {
        Write-Host "  keep:    $($c.objectid) (appmodule exists)" -ForegroundColor DarkGray
    } else {
        Write-Host "  orphan:  $($c.objectid) - removing solutioncomponent $($c.solutioncomponentid)..." -ForegroundColor Yellow
        $body = @{
            ComponentId        = $c.objectid
            ComponentType      = 80
            SolutionUniqueName = 'CredentialLifecycleManager'
        } | ConvertTo-Json -Compress
        try {
            Invoke-RestMethod -Method POST -Uri "$apiBase/RemoveSolutionComponent" -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
            Write-Host "    removed via RemoveSolutionComponent" -ForegroundColor Green
        } catch {
            Write-Host "    RemoveSolutionComponent failed, trying DELETE on solutioncomponents..." -ForegroundColor Yellow
            Invoke-RestMethod -Method DELETE -Uri "$apiBase/solutioncomponents($($c.solutioncomponentid))" -Headers $headers | Out-Null
            Write-Host "    removed via DELETE" -ForegroundColor Green
        }
    }
}
Write-Host "Done. You can now re-run Deploy-CLMApp.ps1." -ForegroundColor Green
