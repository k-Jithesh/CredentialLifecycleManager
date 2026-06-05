<#
.SYNOPSIS
    Seeds starter clm_ownerrule rows so the CLM Owner Resolver flow has work to do.

.DESCRIPTION
    Idempotent upsert by rule name (clm_name). Resolves user emails -> systemuserid
    and team names -> teamid against the target Dataverse env. Re-runs are safe;
    existing rules are updated in place.

    Edit $Rules below to customise.

.PARAMETER EnvironmentUrl
    e.g. https://<DATAVERSE_HOST>

.PARAMETER TenantId
    AAD tenant for token acquisition. Optional; defaults to the current Az context tenant.

.EXAMPLE
    pwsh ./Seed-CLMOwnerRules.ps1 -EnvironmentUrl https://<DATAVERSE_HOST>

.NOTES
    Requires PowerShell 7+ and Az.Accounts. The signed-in user must hold a security
    role with read/create/update on clm_ownerrule (e.g. System Customizer).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [string] $TenantId,
    [string] $AccountId = '<OPS_EMAIL>',
    [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'

# ---------- Edit your rules here ----------
# Match scope option set values: DisplayName=700000000, Tag=700000001,
# Environment=700000002, KeyVaultName=700000003, ResourceGroup=700000004.
$Rules = @(
    @{ Name = 'CLM-prefix to me';        Priority =  10; Scope = 700000000; Pattern = 'clm-';      User = '<OPS_EMAIL>'; Team = $null }
    @{ Name = 'AT- prefix to AT team';   Priority =  20; Scope = 700000000; Pattern = 'at-';       User = $null;                   Team = 'AT Integration Team' }
    @{ Name = 'CRM- prefix to D365 Ops'; Priority =  30; Scope = 700000000; Pattern = 'crm-';      User = $null;                   Team = 'D365 Ops' }
    @{ Name = 'Prod env to Platform Ops';Priority =  40; Scope = 700000002; Pattern = 'prod';      User = $null;                   Team = 'Platform Ops' }
    @{ Name = '-prod- vault to PlatOps'; Priority =  50; Scope = 700000003; Pattern = '-prod-';    User = $null;                   Team = 'Platform Ops' }
    @{ Name = 'Catch-all to me';         Priority = 999; Scope = 700000000; Pattern = '';          User = '<OPS_EMAIL>'; Team = $null }
)
# -------------------------------------------

# --- Auth: Az.Accounts -> Dataverse token ---
if (-not (Get-Module -ListAvailable Az.Accounts)) {
    Write-Host 'Installing Az.Accounts...' -ForegroundColor Yellow
    Install-Module Az.Accounts -Scope CurrentUser -Force -AllowClobber
}
Import-Module Az.Accounts -ErrorAction Stop

$resource = $EnvironmentUrl.TrimEnd('/')
$ctx = Get-AzContext
if (-not $ctx -or ($TenantId -and $ctx.Tenant.Id -ne $TenantId)) {
    $connectArgs = @{ ErrorAction = 'Stop' }
    if ($TenantId)  { $connectArgs.TenantId  = $TenantId }
    if ($AccountId) { $connectArgs.AccountId = $AccountId }
    try {
        Connect-AzAccount @connectArgs | Out-Null
    } catch {
        Write-Warning "Interactive sign-in failed: $($_.Exception.Message)"
        $connectArgs.UseDeviceAuthentication = $true
        Connect-AzAccount @connectArgs | Out-Null
    }
}
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

# --- Helpers ---
function Invoke-Dv {
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Path,
        [object] $Body,
        [hashtable] $ExtraHeaders
    )
    $url = "$apiBase/$Path"
    $h = $headers.Clone()
    if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $h[$k] = $ExtraHeaders[$k] } }
    $params = @{ Method = $Method; Uri = $url; Headers = $h; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
    }
    Invoke-RestMethod @params
}

$userCache = @{}
function Resolve-UserId {
    param([string]$Email)
    if ([string]::IsNullOrWhiteSpace($Email)) { return $null }
    if ($userCache.ContainsKey($Email)) { return $userCache[$Email] }
    $esc = $Email.Replace("'", "''")
    $r = Invoke-Dv -Method GET -Path "systemusers?`$filter=internalemailaddress eq '$esc' or domainname eq '$esc'&`$select=systemuserid,fullname&`$top=1"
    if (-not $r.value -or $r.value.Count -eq 0) {
        Write-Warning "  ! User not found: $Email"
        $userCache[$Email] = $null
        return $null
    }
    $id = [string]$r.value[0].systemuserid
    Write-Host ("   user  '{0}' -> {1} ({2})" -f $Email, $r.value[0].fullname, $id) -ForegroundColor DarkGray
    $userCache[$Email] = $id
    return $id
}

$teamCache = @{}
function Resolve-TeamId {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    if ($teamCache.ContainsKey($Name)) { return $teamCache[$Name] }
    $esc = $Name.Replace("'", "''")
    # teamtype 0 = Owner team (the kind you usually want for ownership)
    $r = Invoke-Dv -Method GET -Path "teams?`$filter=name eq '$esc'&`$select=teamid,name,teamtype&`$top=5"
    if (-not $r.value -or $r.value.Count -eq 0) {
        Write-Warning "  ! Team not found: $Name"
        $teamCache[$Name] = $null
        return $null
    }
    # Prefer Owner team (type 0) if multiple
    $picked = $r.value | Where-Object { $_.teamtype -eq 0 } | Select-Object -First 1
    if (-not $picked) { $picked = $r.value[0] }
    $id = [string]$picked.teamid
    Write-Host ("   team  '{0}' -> teamid {1}" -f $Name, $id) -ForegroundColor DarkGray
    $teamCache[$Name] = $id
    return $id
}

function Get-RuleByName {
    param([string]$Name)
    $esc = $Name.Replace("'", "''")
    $r = Invoke-Dv -Method GET -Path "clm_ownerrules?`$filter=clm_name eq '$esc'&`$select=clm_ownerruleid&`$top=1"
    if ($r.value -and $r.value.Count -gt 0) { return [string]$r.value[0].clm_ownerruleid }
    return $null
}

# --- Apply ---
Write-Host ""
Write-Host "Seeding clm_ownerrule rows against $resource" -ForegroundColor Cyan
Write-Host ("Rules to upsert: {0}" -f $Rules.Count) -ForegroundColor Cyan
Write-Host ""

$created = 0; $updated = 0; $skipped = 0; $warned = 0

foreach ($rule in $Rules) {
    Write-Host (" - {0}  (priority {1}, scope {2}, pattern '{3}')" -f $rule.Name, $rule.Priority, $rule.Scope, $rule.Pattern) -ForegroundColor White

    $userId = Resolve-UserId -Email $rule.User
    $teamId = Resolve-TeamId -Name $rule.Team

    if (-not $userId -and -not $teamId -and ($rule.User -or $rule.Team)) {
        Write-Warning "   neither user nor team could be resolved -- skipping rule '$($rule.Name)'"
        $warned++; continue
    }

    $body = [ordered]@{
        clm_name        = $rule.Name
        clm_priority    = [int]$rule.Priority
        clm_matchscope  = [int]$rule.Scope
        clm_matchpattern = [string]$rule.Pattern
        clm_isactive    = $true
    }
    if ($userId) { $body.'clm_assigntouser@odata.bind' = "/systemusers($userId)" }
    if ($teamId) { $body.'clm_assigntoteam@odata.bind' = "/teams($teamId)" }

    if ($WhatIf) {
        Write-Host "   [WhatIf] would upsert:" -ForegroundColor Yellow
        $body | Format-Table | Out-String | Write-Host
        continue
    }

    $existingId = Get-RuleByName -Name $rule.Name
    if ($existingId) {
        # PATCH (update)
        Invoke-Dv -Method PATCH -Path "clm_ownerrules($existingId)" -Body $body | Out-Null
        Write-Host "   updated existing rule ($existingId)" -ForegroundColor DarkGreen
        $updated++
    } else {
        # POST (create); ask for the new id back
        $r = Invoke-Dv -Method POST -Path "clm_ownerrules" -Body $body -ExtraHeaders @{ 'Prefer' = 'return=representation' }
        Write-Host ("   created new rule ({0})" -f $r.clm_ownerruleid) -ForegroundColor Green
        $created++
    }
}

Write-Host ""
Write-Host ("Done. Created: {0}, updated: {1}, warned: {2}" -f $created, $updated, $warned) -ForegroundColor Cyan
Write-Host "Verify in Power Apps -> Tables -> Owner Rule, or run the OwnerResolver flow on demand." -ForegroundColor Cyan
