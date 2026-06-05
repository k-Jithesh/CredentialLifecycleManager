<#
.SYNOPSIS
    Adds clm_ownertag (text) and clm_ownersource (choice) columns to clm_credential,
    plus a global option set clm_ownersource. Idempotent.

.DESCRIPTION
    Required for the tag-source-of-truth ownership flow. Run once per environment.

.PARAMETER EnvironmentUrl
    e.g. https://<DATAVERSE_HOST>

.EXAMPLE
    pwsh ./Add-CLMOwnerColumns.ps1 -EnvironmentUrl https://<DATAVERSE_HOST>

.NOTES
    Requires PowerShell 7+ and Az.Accounts. Signed-in user must be System Customizer.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [string] $TenantId,
    [string] $AccountId = '<OPS_EMAIL>',
    [string] $SolutionUniqueName = 'CredentialLifecycleManager'
)

$ErrorActionPreference = 'Stop'

# --- Auth ---
if (-not (Get-Module -ListAvailable Az.Accounts)) {
    Install-Module Az.Accounts -Scope CurrentUser -Force -AllowClobber
}
Import-Module Az.Accounts -ErrorAction Stop

$resource = $EnvironmentUrl.TrimEnd('/')
$ctx = Get-AzContext
if (-not $ctx -or ($TenantId -and $ctx.Tenant.Id -ne $TenantId)) {
    $args = @{ ErrorAction = 'Stop' }
    if ($TenantId)  { $args.TenantId  = $TenantId }
    if ($AccountId) { $args.AccountId = $AccountId }
    try { Connect-AzAccount @args | Out-Null }
    catch { $args.UseDeviceAuthentication = $true; Connect-AzAccount @args | Out-Null }
}
$tokArgs = @{ ResourceUrl = $resource }
if ($TenantId) { $tokArgs.TenantId = $TenantId }
$token = (Get-AzAccessToken @tokArgs).Token
$headers = @{
    Authorization      = "Bearer $token"
    'OData-MaxVersion' = '4.0'
    'OData-Version'    = '4.0'
    Accept             = 'application/json'
    'Content-Type'     = 'application/json; charset=utf-8'
    'MSCRM.SolutionUniqueName' = $SolutionUniqueName
}
$apiBase = "$resource/api/data/v9.2"

function Invoke-Dv {
    param([string]$Method, [string]$Path, [object]$Body)
    $url = "$apiBase/$Path"
    $params = @{ Method = $Method; Uri = $url; Headers = $headers; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
    }
    try { Invoke-RestMethod @params }
    catch {
        $msg = $_.Exception.Message
        $resp = $_.ErrorDetails.Message
        $combined = "$msg`n$resp"
        if ($combined -match 'already exists|duplicate|in use|0x80060891|0x80044150') {
            Write-Host "   already exists -- skipping" -ForegroundColor DarkYellow
            return $null
        }
        throw "$msg`n$resp"
    }
}

Write-Host "Adding columns to clm_credential in $resource" -ForegroundColor Cyan

# 1. Column: clm_ownertag (Text 200)
Write-Host "`n[1/2] Adding column clm_ownertag (Text 200) to clm_credential..." -ForegroundColor White
$colTag = @{
    '@odata.type' = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'
    SchemaName = 'clm_ownertag'
    LogicalName = 'clm_ownertag'
    AttributeType = 'String'
    AttributeTypeName = @{ Value = 'StringType' }
    RequiredLevel = @{ Value = 'None' }
    MaxLength = 200
    FormatName = @{ Value = 'Text' }
    DisplayName = @{
        LocalizedLabels = @(@{ Label = 'Owner Tag'; LanguageCode = 1033 })
    }
    Description = @{
        LocalizedLabels = @(@{ Label = 'Raw owner identifier captured at source (e.g. Azure tag.Owner, or AAD app first owner UPN). Drives owner re-assignment when present.'; LanguageCode = 1033 })
    }
}
Invoke-Dv -Method POST -Path 'EntityDefinitions(LogicalName=''clm_credential'')/Attributes' -Body $colTag | Out-Null

# 2. Column: clm_ownersource (Picklist with LOCAL option set)
Write-Host "`n[2/2] Adding column clm_ownersource (Choice) to clm_credential..." -ForegroundColor White
$colSource = @{
    '@odata.type' = 'Microsoft.Dynamics.CRM.PicklistAttributeMetadata'
    SchemaName = 'clm_ownersource'
    LogicalName = 'clm_ownersource'
    AttributeType = 'Picklist'
    AttributeTypeName = @{ Value = 'PicklistType' }
    RequiredLevel = @{ Value = 'None' }
    OptionSet = @{
        '@odata.type' = 'Microsoft.Dynamics.CRM.OptionSetMetadata'
        IsGlobal = $false
        OptionSetType = 'Picklist'
        Options = @(
            @{ Value = 1000000000; Label = @{ LocalizedLabels = @(@{ Label = 'Tag';      LanguageCode = 1033 }) }; Description = @{ LocalizedLabels = @(@{ Label = 'From an Azure resource tag (e.g. tag.Owner = email).'; LanguageCode = 1033 }) } }
            @{ Value = 1000000001; Label = @{ LocalizedLabels = @(@{ Label = 'AADOwner'; LanguageCode = 1033 }) }; Description = @{ LocalizedLabels = @(@{ Label = 'From the AAD application registration first owner.'; LanguageCode = 1033 }) } }
            @{ Value = 1000000002; Label = @{ LocalizedLabels = @(@{ Label = 'Rule';     LanguageCode = 1033 }) }; Description = @{ LocalizedLabels = @(@{ Label = 'From a clm_ownerrule match.'; LanguageCode = 1033 }) } }
            @{ Value = 1000000003; Label = @{ LocalizedLabels = @(@{ Label = 'Manual';   LanguageCode = 1033 }) }; Description = @{ LocalizedLabels = @(@{ Label = 'Set by a human in the UI.'; LanguageCode = 1033 }) } }
        )
    }
    DisplayName = @{
        LocalizedLabels = @(@{ Label = 'Owner Source'; LanguageCode = 1033 })
    }
    Description = @{
        LocalizedLabels = @(@{ Label = 'How the current owner was determined (Tag, AADOwner, Rule, Manual). Used to decide whether ownership can be re-assigned automatically.'; LanguageCode = 1033 })
    }
}
Invoke-Dv -Method POST -Path 'EntityDefinitions(LogicalName=''clm_credential'')/Attributes' -Body $colSource | Out-Null

Write-Host "`nDone. Reload your solution / app to see the new columns." -ForegroundColor Cyan
Write-Host "Next: import CLMDiscoveryFlow 1.0.0.16 (populates clm_ownertag) and CLMOwnerResolver 1.0.0.3 (consumes it)." -ForegroundColor Cyan
