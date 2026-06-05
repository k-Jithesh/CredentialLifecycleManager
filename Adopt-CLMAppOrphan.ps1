<#
Adopts an orphan appmodule solutioncomponent by creating an appmodule with
the exact GUID the orphan points at. After this runs the solution is
consistent and Deploy-CLMApp.ps1 will succeed (it will PATCH the existing
appmodule on the next run).
#>
param(
    [string] $EnvironmentUrl = 'https://<DATAVERSE_HOST>',
    [Parameter(Mandatory)] [string] $OrphanAppModuleId,
    [Parameter(Mandatory)] [string] $WebResourceId,
    [string] $TenantId,
    [string] $UniqueName  = 'clm_clmconsole',
    [string] $Name        = 'Credential Lifecycle Manager',
    [string] $Description = 'Console for browsing and managing tracked credentials, discovery runs and coverage gaps.'
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

$body = @{
    appmoduleid       = $OrphanAppModuleId
    uniquename        = $UniqueName
    name              = $Name
    description       = $Description
    clienttype        = 4
    navigationtype    = 1
    appmoduleversion  = '1.0.0.0'
    webresourceid     = $WebResourceId
}
$json = ($body | ConvertTo-Json -Compress)

Write-Host "Creating appmodule $UniqueName with id $OrphanAppModuleId..." -ForegroundColor Cyan
Invoke-RestMethod -Method POST -Uri "$apiBase/appmodules" -Headers $headers -Body ([Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
Write-Host "Created. Re-run Deploy-CLMApp.ps1 to attach sitemap + views." -ForegroundColor Green
