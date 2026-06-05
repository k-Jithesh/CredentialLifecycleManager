<#
.SYNOPSIS
    Creates the curated system views (savedquery rows) for the CLM model-driven app.

.DESCRIPTION
    Adds 8 public views across clm_credential, clm_renewalevent, clm_ownerrule,
    clm_coveragegap. Idempotent — upserts by view name within each entity.

.PARAMETER EnvironmentUrl
    e.g. https://<DATAVERSE_HOST>

.PARAMETER SolutionUniqueName
    Optional. If set, views are added to the named solution. Default omits the
    MSCRM.SolutionUniqueName header (views land in Default Solution).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [string] $TenantId,
    [string] $AccountId = '<OPS_EMAIL>',
    [string] $SolutionUniqueName
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable Az.Accounts)) {
    Install-Module Az.Accounts -Scope CurrentUser -Force -AllowClobber
}
Import-Module Az.Accounts -ErrorAction Stop

$resource = $EnvironmentUrl.TrimEnd('/')
$ctx = Get-AzContext
if (-not $ctx -or ($TenantId -and $ctx.Tenant.Id -ne $TenantId)) {
    $a = @{ ErrorAction = 'Stop' }
    if ($TenantId)  { $a.TenantId  = $TenantId }
    if ($AccountId) { $a.AccountId = $AccountId }
    try { Connect-AzAccount @a | Out-Null }
    catch { $a.UseDeviceAuthentication = $true; Connect-AzAccount @a | Out-Null }
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
}
if ($SolutionUniqueName) { $headers['MSCRM.SolutionUniqueName'] = $SolutionUniqueName }
$apiBase = "$resource/api/data/v9.2"

function Invoke-Dv {
    param([string]$Method, [string]$Path, [object]$Body)
    $url = "$apiBase/$Path"
    $params = @{ Method = $Method; Uri = $url; Headers = $headers; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 30 -Compress)
    }
    Invoke-RestMethod @params
}

function Get-SavedQueryId {
    param([string]$EntityName, [string]$ViewName)
    $esc = $ViewName.Replace("'", "''")
    $r = Invoke-Dv -Method GET -Path "savedqueries?`$filter=returnedtypecode eq '$EntityName' and name eq '$esc'&`$select=savedqueryid&`$top=1"
    if ($r.value -and $r.value.Count -gt 0) { return [string]$r.value[0].savedqueryid }
    return $null
}

function Upsert-View {
    param(
        [string]$EntityName,
        [string]$ViewName,
        [string]$Description,
        [string]$FetchXml,
        [string]$LayoutXml
    )
    Write-Host (" - {0} : {1}" -f $EntityName, $ViewName) -ForegroundColor White
    $body = [ordered]@{
        name             = $ViewName
        description      = $Description
        returnedtypecode = $EntityName
        fetchxml         = $FetchXml
        layoutxml        = $LayoutXml
        querytype        = 0
        statecode        = 0
        statuscode       = 1
        iscustomizable   = @{ Value = $true; CanBeChanged = $true; ManagedPropertyLogicalName = 'iscustomizable' }
    }
    $existingId = Get-SavedQueryId -EntityName $EntityName -ViewName $ViewName
    if ($existingId) {
        Invoke-Dv -Method PATCH -Path "savedqueries($existingId)" -Body $body | Out-Null
        Write-Host "   updated ($existingId)" -ForegroundColor DarkGreen
    } else {
        $r = Invoke-Dv -Method POST -Path "savedqueries" -Body $body -ErrorAction Stop
        Write-Host "   created" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Adding CLM system views to $resource" -ForegroundColor Cyan
if ($SolutionUniqueName) {
    Write-Host "Target solution: $SolutionUniqueName" -ForegroundColor Cyan
}
Write-Host ""

# ----------------- clm_credential views -----------------

$credLayout = @"
<grid name="resultset" object="1" jump="clm_name" select="1" preview="1" icon="1">
  <row name="result" id="clm_credentialid">
    <cell name="clm_name"             width="220" />
    <cell name="clm_status"           width="110" />
    <cell name="clm_credentialtype"   width="100" />
    <cell name="clm_sourcesystem"     width="140" />
    <cell name="clm_expirydate"       width="140" />
    <cell name="clm_daysuntilexpiry"  width="100" />
    <cell name="clm_owneruser"        width="160" />
    <cell name="clm_environment"      width="160" />
  </row>
</grid>
"@

Upsert-View -EntityName 'clm_credential' -ViewName 'All Active Credentials' `
    -Description 'All credentials that are not Decommissioned, ordered by expiry.' `
    -FetchXml @"
<fetch version="1.0" mapping="logical">
  <entity name="clm_credential">
    <attribute name="clm_credentialid" />
    <attribute name="clm_name" />
    <attribute name="clm_status" />
    <attribute name="clm_credentialtype" />
    <attribute name="clm_sourcesystem" />
    <attribute name="clm_expirydate" />
    <attribute name="clm_daysuntilexpiry" />
    <attribute name="clm_owneruser" />
    <attribute name="clm_environment" />
    <order attribute="clm_expirydate" descending="false" />
    <filter type="and">
      <condition attribute="clm_status" operator="ne" value="300000007" />
    </filter>
  </entity>
</fetch>
"@ -LayoutXml $credLayout

Upsert-View -EntityName 'clm_credential' -ViewName 'Expiring in 30 Days' `
    -Description 'Credentials expiring within 30 days (active, not suppressed).' `
    -FetchXml @"
<fetch version="1.0" mapping="logical">
  <entity name="clm_credential">
    <attribute name="clm_credentialid" />
    <attribute name="clm_name" />
    <attribute name="clm_status" />
    <attribute name="clm_credentialtype" />
    <attribute name="clm_sourcesystem" />
    <attribute name="clm_expirydate" />
    <attribute name="clm_daysuntilexpiry" />
    <attribute name="clm_owneruser" />
    <attribute name="clm_environment" />
    <order attribute="clm_expirydate" descending="false" />
    <filter type="and">
      <condition attribute="clm_daysuntilexpiry" operator="le" value="30" />
      <condition attribute="clm_status" operator="ne" value="300000005" />
      <condition attribute="clm_status" operator="ne" value="300000007" />
    </filter>
  </entity>
</fetch>
"@ -LayoutXml $credLayout

Upsert-View -EntityName 'clm_credential' -ViewName 'Expiring in 7 Days' `
    -Description 'Critical: credentials expiring within 7 days.' `
    -FetchXml @"
<fetch version="1.0" mapping="logical">
  <entity name="clm_credential">
    <attribute name="clm_credentialid" />
    <attribute name="clm_name" />
    <attribute name="clm_status" />
    <attribute name="clm_credentialtype" />
    <attribute name="clm_sourcesystem" />
    <attribute name="clm_expirydate" />
    <attribute name="clm_daysuntilexpiry" />
    <attribute name="clm_owneruser" />
    <order attribute="clm_expirydate" descending="false" />
    <filter type="and">
      <condition attribute="clm_daysuntilexpiry" operator="le" value="7" />
      <condition attribute="clm_status" operator="ne" value="300000005" />
      <condition attribute="clm_status" operator="ne" value="300000007" />
    </filter>
  </entity>
</fetch>
"@ -LayoutXml $credLayout

Upsert-View -EntityName 'clm_credential' -ViewName 'Expired' `
    -Description 'Credentials past expiry, not Decommissioned.' `
    -FetchXml @"
<fetch version="1.0" mapping="logical">
  <entity name="clm_credential">
    <attribute name="clm_credentialid" />
    <attribute name="clm_name" />
    <attribute name="clm_status" />
    <attribute name="clm_sourcesystem" />
    <attribute name="clm_expirydate" />
    <attribute name="clm_daysuntilexpiry" />
    <attribute name="clm_owneruser" />
    <attribute name="clm_environment" />
    <order attribute="clm_expirydate" descending="true" />
    <filter type="and">
      <condition attribute="clm_daysuntilexpiry" operator="lt" value="0" />
      <condition attribute="clm_status" operator="ne" value="300000007" />
    </filter>
  </entity>
</fetch>
"@ -LayoutXml $credLayout

Upsert-View -EntityName 'clm_credential' -ViewName 'Orphans (No Owner)' `
    -Description 'Active credentials with no owneruser AND no ownerteam.' `
    -FetchXml @"
<fetch version="1.0" mapping="logical">
  <entity name="clm_credential">
    <attribute name="clm_credentialid" />
    <attribute name="clm_name" />
    <attribute name="clm_status" />
    <attribute name="clm_sourcesystem" />
    <attribute name="clm_expirydate" />
    <attribute name="clm_daysuntilexpiry" />
    <attribute name="clm_environment" />
    <attribute name="clm_ownertag" />
    <order attribute="clm_expirydate" descending="false" />
    <filter type="and">
      <condition attribute="clm_owneruser" operator="null" />
      <condition attribute="clm_ownerteam" operator="null" />
      <condition attribute="clm_status" operator="ne" value="300000007" />
      <condition attribute="clm_name" operator="ne" value="SYSTEM" />
    </filter>
  </entity>
</fetch>
"@ -LayoutXml $credLayout

Upsert-View -EntityName 'clm_credential' -ViewName 'My Credentials' `
    -Description 'Credentials where the current user is owneruser.' `
    -FetchXml @"
<fetch version="1.0" mapping="logical">
  <entity name="clm_credential">
    <attribute name="clm_credentialid" />
    <attribute name="clm_name" />
    <attribute name="clm_status" />
    <attribute name="clm_credentialtype" />
    <attribute name="clm_sourcesystem" />
    <attribute name="clm_expirydate" />
    <attribute name="clm_daysuntilexpiry" />
    <attribute name="clm_environment" />
    <order attribute="clm_expirydate" descending="false" />
    <filter type="and">
      <condition attribute="clm_owneruser" operator="eq-userid" />
      <condition attribute="clm_status" operator="ne" value="300000007" />
    </filter>
  </entity>
</fetch>
"@ -LayoutXml $credLayout

# ----------------- clm_renewalevent views -----------------

$evtLayout = @"
<grid name="resultset" object="1" jump="clm_name" select="1" preview="1" icon="1">
  <row name="result" id="clm_renewaleventid">
    <cell name="clm_occurredon"  width="150" />
    <cell name="clm_name"        width="280" />
    <cell name="clm_action"      width="140" />
    <cell name="clm_credentialid" width="200" />
    <cell name="clm_notes"       width="400" />
  </row>
</grid>
"@

Upsert-View -EntityName 'clm_renewalevent' -ViewName 'Recent Events (7 days)' `
    -Description 'All renewal events from the last 7 days, newest first.' `
    -FetchXml @"
<fetch version="1.0" mapping="logical">
  <entity name="clm_renewalevent">
    <attribute name="clm_renewaleventid" />
    <attribute name="clm_name" />
    <attribute name="clm_occurredon" />
    <attribute name="clm_action" />
    <attribute name="clm_credentialid" />
    <attribute name="clm_notes" />
    <order attribute="clm_occurredon" descending="true" />
    <filter type="and">
      <condition attribute="clm_occurredon" operator="last-x-days" value="7" />
    </filter>
  </entity>
</fetch>
"@ -LayoutXml $evtLayout

Upsert-View -EntityName 'clm_renewalevent' -ViewName 'Failures (Orphaned / Reminder Failed)' `
    -Description 'Events with action MarkedOrphaned (covers flow failures + tag-resolution misses).' `
    -FetchXml @"
<fetch version="1.0" mapping="logical">
  <entity name="clm_renewalevent">
    <attribute name="clm_renewaleventid" />
    <attribute name="clm_name" />
    <attribute name="clm_occurredon" />
    <attribute name="clm_action" />
    <attribute name="clm_credentialid" />
    <attribute name="clm_notes" />
    <order attribute="clm_occurredon" descending="true" />
    <filter type="and">
      <condition attribute="clm_action" operator="eq" value="600000009" />
    </filter>
  </entity>
</fetch>
"@ -LayoutXml $evtLayout

# ----------------- clm_ownerrule views -----------------

$ruleLayout = @"
<grid name="resultset" object="1" jump="clm_name" select="1" preview="1" icon="1">
  <row name="result" id="clm_ownerruleid">
    <cell name="clm_priority"        width="80" />
    <cell name="clm_name"            width="220" />
    <cell name="clm_matchscope"      width="140" />
    <cell name="clm_matchpattern"    width="180" />
    <cell name="clm_assigntouser"    width="180" />
    <cell name="clm_assigntoteam"    width="180" />
    <cell name="clm_matchcount"      width="100" />
    <cell name="clm_lastmatchedon"   width="150" />
    <cell name="clm_isactive"        width="80" />
  </row>
</grid>
"@

Upsert-View -EntityName 'clm_ownerrule' -ViewName 'Active Rules (by Priority)' `
    -Description 'All active rules, ordered by priority asc (lowest number wins).' `
    -FetchXml @"
<fetch version="1.0" mapping="logical">
  <entity name="clm_ownerrule">
    <attribute name="clm_ownerruleid" />
    <attribute name="clm_name" />
    <attribute name="clm_priority" />
    <attribute name="clm_matchscope" />
    <attribute name="clm_matchpattern" />
    <attribute name="clm_assigntouser" />
    <attribute name="clm_assigntoteam" />
    <attribute name="clm_matchcount" />
    <attribute name="clm_lastmatchedon" />
    <attribute name="clm_isactive" />
    <order attribute="clm_priority" descending="false" />
    <filter type="and">
      <condition attribute="clm_isactive" operator="eq" value="1" />
    </filter>
  </entity>
</fetch>
"@ -LayoutXml $ruleLayout

# ----------------- clm_coveragegap views -----------------

$gapLayout = @"
<grid name="resultset" object="1" jump="clm_name" select="1" preview="1" icon="1">
  <row name="result" id="clm_coveragegapid">
    <cell name="clm_name"             width="240" />
    <cell name="clm_scopetype"        width="140" />
    <cell name="clm_scopename"        width="200" />
    <cell name="clm_gaptype"          width="160" />
    <cell name="clm_status"           width="120" />
    <cell name="clm_lasthttpstatus"   width="100" />
    <cell name="clm_firstdetectedon"  width="150" />
    <cell name="clm_lastattemptedon"  width="150" />
  </row>
</grid>
"@

Upsert-View -EntityName 'clm_coveragegap' -ViewName 'Open Gaps' `
    -Description 'Coverage gaps that are Open or Acknowledged (i.e. still actionable).' `
    -FetchXml @"
<fetch version="1.0" mapping="logical">
  <entity name="clm_coveragegap">
    <attribute name="clm_coveragegapid" />
    <attribute name="clm_name" />
    <attribute name="clm_scopetype" />
    <attribute name="clm_scopename" />
    <attribute name="clm_gaptype" />
    <attribute name="clm_status" />
    <attribute name="clm_lasthttpstatus" />
    <attribute name="clm_firstdetectedon" />
    <attribute name="clm_lastattemptedon" />
    <order attribute="clm_lastattemptedon" descending="true" />
    <filter type="and">
      <condition attribute="clm_status" operator="in">
        <value>950000000</value>
        <value>950000001</value>
      </condition>
    </filter>
  </entity>
</fetch>
"@ -LayoutXml $gapLayout

Write-Host ""
Write-Host "Done." -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host " 1. Open https://make.powerapps.com -> target env -> + New -> App -> Model-driven app." -ForegroundColor Yellow
Write-Host " 2. Name: 'Credential Lifecycle', then + Add page -> Dataverse table -> add:" -ForegroundColor Yellow
Write-Host "      clm_credential (set as Home), clm_renewalevent, clm_ownerrule, clm_sourceenvironment, clm_coveragegap" -ForegroundColor Yellow
Write-Host " 3. Save -> Publish -> Play. New views appear automatically in the view selector." -ForegroundColor Yellow
Write-Host " 4. Optional: customise the sitemap via Settings -> Site map and paste the contents of CLMApp_Sitemap.xml." -ForegroundColor Yellow
