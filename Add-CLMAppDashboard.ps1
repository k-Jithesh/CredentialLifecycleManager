<#
.SYNOPSIS
    Creates the CLM Operations Dashboard - a 2-column, 3-row system dashboard
    embedding charts created by Add-CLMAppCharts.ps1 and two list panels.

.DESCRIPTION
    System dashboard (objecttypecode=null, type=0, formactivationstate=1).
    Layout (4 cells in a 2x2 grid):
      ┌──────────────────────────┬──────────────────────────┐
      │ Credentials by Status    │ Credentials by Source    │
      │ (pie)                    │ System (column)          │
      ├──────────────────────────┼──────────────────────────┤
      │ Open Coverage Gaps       │ Recent Renewal Events    │
      │ (list)                   │ (list, last 7 days)      │
      └──────────────────────────┴──────────────────────────┘

    Idempotent - upserts by name.

.PARAMETER EnvironmentUrl
    e.g. https://<DATAVERSE_HOST>
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [string] $TenantId,
    [string] $AccountId = '<OPS_EMAIL>',
    [string] $SolutionUniqueName,
    [string] $DashboardName = 'CLM Operations'
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

# --- Resolve chart + view ids ---

function Get-ChartId {
    param([string]$EntityCode, [string]$Name)
    $esc = $Name.Replace("'", "''")
    $r = Invoke-Dv -Method GET -Path "savedqueryvisualizations?`$filter=primaryentitytypecode eq '$EntityCode' and name eq '$esc'&`$select=savedqueryvisualizationid&`$top=1"
    if (-not $r.value -or $r.value.Count -eq 0) { throw "Chart '$Name' not found for entity '$EntityCode'. Run Add-CLMAppCharts.ps1 first." }
    return [string]$r.value[0].savedqueryvisualizationid
}

function Get-ViewId {
    param([string]$EntityName, [string]$ViewName)
    $esc = $ViewName.Replace("'", "''")
    $r = Invoke-Dv -Method GET -Path "savedqueries?`$filter=returnedtypecode eq '$EntityName' and name eq '$esc'&`$select=savedqueryid&`$top=1"
    if (-not $r.value -or $r.value.Count -eq 0) { throw "View '$ViewName' not found for entity '$EntityName'. Run Add-CLMAppViews.ps1 first." }
    return [string]$r.value[0].savedqueryid
}

Write-Host "Resolving chart + view ids..." -ForegroundColor Cyan
$chartStatusId    = Get-ChartId -EntityCode 'clm_credential'    -Name 'Credentials by Status'
$chartSourceId    = Get-ChartId -EntityCode 'clm_credential'    -Name 'Credentials by Source System'
$viewOpenGapsId   = Get-ViewId  -EntityName 'clm_coveragegap'   -ViewName 'Open Gaps'
$viewRecentEvtsId = Get-ViewId  -EntityName 'clm_renewalevent'  -ViewName 'Recent Events (7 days)'
$viewAllCredsId   = Get-ViewId  -EntityName 'clm_credential'    -ViewName 'All Active Credentials'

Write-Host "  Credentials by Status chart:   $chartStatusId"   -ForegroundColor DarkGray
Write-Host "  Credentials by Source chart:   $chartSourceId"   -ForegroundColor DarkGray
Write-Host "  All Active Credentials view:   $viewAllCredsId"  -ForegroundColor DarkGray
Write-Host "  Open Gaps view:                $viewOpenGapsId"  -ForegroundColor DarkGray
Write-Host "  Recent Events view:            $viewRecentEvtsId" -ForegroundColor DarkGray

# --- Build dashboard FormXML ---
# 2x2 grid: 12 columns total, each cell 6 cols wide.
# Cell heights: 200 each.

$formXml = @"
<form>
  <tabs>
    <tab name="tab0" id="{a3a3a3a3-1111-2222-3333-444444444444}" showlabel="false" expanded="true" verticallayout="true">
      <labels><label description="CLM Operations" languagecode="1033" /></labels>
      <columns>
        <column width="100%">
          <sections>
            <section name="sec0" showlabel="false" showbar="false" columns="2" labelwidth="115" id="{b1b1b1b1-1111-2222-3333-444444444444}">
              <labels><label description="Row 1" languagecode="1033" /></labels>
              <rows>
                <row>
                  <cell id="{c0000001-0000-0000-0000-000000000001}" showlabel="false" rowspan="6" colspan="1">
                    <labels><label description="Credentials by Status" languagecode="1033" /></labels>
                    <control id="ChartStatus" classid="{E7A81278-8635-4D9E-8D4D-59480B391C5B}">
                      <parameters>
                        <ViewId>{$viewAllCredsId}</ViewId>
                        <IsUserView>false</IsUserView>
                        <TargetEntityType>clm_credential</TargetEntityType>
                        <AutoExpand>Fixed</AutoExpand>
                        <EnableQuickFind>false</EnableQuickFind>
                        <EnableViewPicker>false</EnableViewPicker>
                        <EnableJumpBar>false</EnableJumpBar>
                        <ChartGridMode>Chart</ChartGridMode>
                        <VisualizationId>{$chartStatusId}</VisualizationId>
                        <EnableChartPicker>false</EnableChartPicker>
                        <RecordsPerPage>10</RecordsPerPage>
                      </parameters>
                    </control>
                  </cell>
                  <cell id="{c0000002-0000-0000-0000-000000000002}" showlabel="false" rowspan="6" colspan="1">
                    <labels><label description="Credentials by Source System" languagecode="1033" /></labels>
                    <control id="ChartSource" classid="{E7A81278-8635-4D9E-8D4D-59480B391C5B}">
                      <parameters>
                        <ViewId>{$viewAllCredsId}</ViewId>
                        <IsUserView>false</IsUserView>
                        <TargetEntityType>clm_credential</TargetEntityType>
                        <AutoExpand>Fixed</AutoExpand>
                        <EnableQuickFind>false</EnableQuickFind>
                        <EnableViewPicker>false</EnableViewPicker>
                        <EnableJumpBar>false</EnableJumpBar>
                        <ChartGridMode>Chart</ChartGridMode>
                        <VisualizationId>{$chartSourceId}</VisualizationId>
                        <EnableChartPicker>false</EnableChartPicker>
                        <RecordsPerPage>10</RecordsPerPage>
                      </parameters>
                    </control>
                  </cell>
                </row>
                <row>
                  <cell id="{c0000003-0000-0000-0000-000000000003}" showlabel="false" rowspan="6" colspan="1">
                    <labels><label description="Open Coverage Gaps" languagecode="1033" /></labels>
                    <control id="ListOpenGaps" classid="{E7A81278-8635-4D9E-8D4D-59480B391C5B}">
                      <parameters>
                        <ViewId>{$viewOpenGapsId}</ViewId>
                        <IsUserView>false</IsUserView>
                        <TargetEntityType>clm_coveragegap</TargetEntityType>
                        <AutoExpand>Fixed</AutoExpand>
                        <EnableQuickFind>false</EnableQuickFind>
                        <EnableViewPicker>true</EnableViewPicker>
                        <EnableJumpBar>false</EnableJumpBar>
                        <ChartGridMode>Grid</ChartGridMode>
                        <VisualizationId />
                        <EnableChartPicker>false</EnableChartPicker>
                        <RecordsPerPage>10</RecordsPerPage>
                      </parameters>
                    </control>
                  </cell>
                  <cell id="{c0000004-0000-0000-0000-000000000004}" showlabel="false" rowspan="6" colspan="1">
                    <labels><label description="Recent Renewal Events" languagecode="1033" /></labels>
                    <control id="ListRecentEvents" classid="{E7A81278-8635-4D9E-8D4D-59480B391C5B}">
                      <parameters>
                        <ViewId>{$viewRecentEvtsId}</ViewId>
                        <IsUserView>false</IsUserView>
                        <TargetEntityType>clm_renewalevent</TargetEntityType>
                        <AutoExpand>Fixed</AutoExpand>
                        <EnableQuickFind>false</EnableQuickFind>
                        <EnableViewPicker>true</EnableViewPicker>
                        <EnableJumpBar>false</EnableJumpBar>
                        <ChartGridMode>Grid</ChartGridMode>
                        <VisualizationId />
                        <EnableChartPicker>false</EnableChartPicker>
                        <RecordsPerPage>10</RecordsPerPage>
                      </parameters>
                    </control>
                  </cell>
                </row>
              </rows>
            </section>
          </sections>
        </column>
      </columns>
    </tab>
  </tabs>
</form>
"@

# --- Upsert system dashboard ---

function Get-DashboardId {
    param([string]$Name)
    $esc = $Name.Replace("'", "''")
    # Type 0 = Dashboard. objecttypecode is null for system dashboards.
    $r = Invoke-Dv -Method GET -Path "systemforms?`$filter=name eq '$esc' and type eq 0&`$select=formid&`$top=1"
    if ($r.value -and $r.value.Count -gt 0) { return [string]$r.value[0].formid }
    return $null
}

$body = [ordered]@{
    name                   = $DashboardName
    description            = 'Top-level CLM ops dashboard: status pie, source breakdown, open gaps, recent events.'
    type                   = 0       # Dashboard
    formactivationstate    = 1       # Active
    objecttypecode         = $null   # System dashboard (not entity-specific)
    formxml                = $formXml
    iscustomizable         = @{ Value = $true; CanBeChanged = $true; ManagedPropertyLogicalName = 'iscustomizable' }
}

Write-Host ""
Write-Host "Upserting dashboard '$DashboardName'..." -ForegroundColor Cyan
$existingId = Get-DashboardId -Name $DashboardName
if ($existingId) {
    Invoke-Dv -Method PATCH -Path "systemforms($existingId)" -Body $body | Out-Null
    Write-Host "  updated ($existingId)" -ForegroundColor DarkGreen
} else {
    $r = Invoke-Dv -Method POST -Path 'systemforms' -Body $body
    Write-Host "  created" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done." -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host " 1. Open the Credential Lifecycle app in Edit." -ForegroundColor Yellow
Write-Host " 2. Top-left sitemap -> + Add page -> Dashboard -> pick 'CLM Operations'." -ForegroundColor Yellow
Write-Host " 3. Save -> Publish. Dashboard appears in the app's left nav." -ForegroundColor Yellow
