<#
.SYNOPSIS
    Creates 3 reusable charts (savedqueryvisualization) for the CLM app:
      1. Credentials by Status        (pie)
      2. Credentials by Source System (column)
      3. Credentials by Reminder Bucket (column, based on clm_remindersent)

    Idempotent - upserts by name within entity.

.PARAMETER EnvironmentUrl
    e.g. https://org6e899b87.crm.dynamics.com
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

function Get-ChartId {
    param([string]$EntityCode, [string]$Name)
    $esc = $Name.Replace("'", "''")
    $r = Invoke-Dv -Method GET -Path "savedqueryvisualizations?`$filter=primaryentitytypecode eq '$EntityCode' and name eq '$esc'&`$select=savedqueryvisualizationid&`$top=1"
    if ($r.value -and $r.value.Count -gt 0) { return [string]$r.value[0].savedqueryvisualizationid }
    return $null
}

function Upsert-Chart {
    param(
        [string]$EntityCode,
        [string]$Name,
        [string]$Description,
        [string]$DataDescription,
        [string]$PresentationDescription
    )
    Write-Host (" - {0} : {1}" -f $EntityCode, $Name) -ForegroundColor White
    $body = [ordered]@{
        name                    = $Name
        description             = $Description
        primaryentitytypecode   = $EntityCode
        datadescription         = $DataDescription
        presentationdescription = $PresentationDescription
        isdefault               = $false
    }
    $id = Get-ChartId -EntityCode $EntityCode -Name $Name
    if ($id) {
        Invoke-Dv -Method PATCH -Path "savedqueryvisualizations($id)" -Body $body | Out-Null
        Write-Host "   updated ($id)" -ForegroundColor DarkGreen
    } else {
        Invoke-Dv -Method POST -Path 'savedqueryvisualizations' -Body $body | Out-Null
        Write-Host "   created" -ForegroundColor Green
    }
}

# ---------- Chart 1: Credentials by Status (pie) ----------

$ddByStatus = @"
<datadefinition>
  <fetchcollection>
    <fetch mapping="logical" aggregate="true">
      <entity name="clm_credential">
        <attribute name="clm_credentialid" alias="aggregate1" aggregate="count" />
        <attribute name="clm_status" groupby="true" alias="groupby_column" />
        <filter>
          <condition attribute="clm_status" operator="ne" value="300000007" />
        </filter>
      </entity>
    </fetch>
  </fetchcollection>
  <categorycollection>
    <category>
      <measurecollection>
        <measure alias="aggregate1" />
      </measurecollection>
    </category>
  </categorycollection>
</datadefinition>
"@

$pdByStatus = @"
<Chart Palette="BrightPastel">
  <Series>
    <Series ChartType="Pie" Font="{0}, 9.5px" LabelForeColor="59, 59, 59" CustomProperties="PieLabelStyle=Outside, DoughnutRadius=60, CollectedThreshold=2, CollectedThresholdUsePercent=True" Name="Series1">
      <SmartLabelStyle Enabled="True" />
          </Series>
  </Series>
  <ChartAreas>
    <ChartArea BorderColor="White" Name="Default">
      <AxisY LineColor="165, 172, 181"><MajorGrid LineColor="239, 242, 246" /><MajorTickMark LineColor="165, 172, 181" /><LabelStyle Font="{0}, 10.5px" ForeColor="59, 59, 59" /></AxisY>
      <AxisX LineColor="165, 172, 181"><MajorGrid LineColor="239, 242, 246" /><MajorTickMark LineColor="165, 172, 181" /><LabelStyle Font="{0}, 10.5px" ForeColor="59, 59, 59" /></AxisX>
    </ChartArea>
  </ChartAreas>
  <Legends>
    <Legend Alignment="Center" LegendStyle="Table" Docking="Right" IsEquallySpacedItems="True" Font="{0}, 11px" ShadowColor="0, 0, 0, 0" ForeColor="59, 59, 59" Name="Legend1" />
  </Legends>
  <Titles>
    <Title Alignment="TopLeft" DockingOffset="-3" Font="{0}, 13px" ForeColor="0, 0, 0" Text="Credentials by Status" Name="Title1" />
  </Titles>
</Chart>
"@

Upsert-Chart -EntityCode 'clm_credential' -Name 'Credentials by Status' `
    -Description 'Pie of active credentials by clm_status (excludes Decommissioned).' `
    -DataDescription $ddByStatus `
    -PresentationDescription $pdByStatus

# ---------- Chart 2: Credentials by Source System (column) ----------

$ddBySource = @"
<datadefinition>
  <fetchcollection>
    <fetch mapping="logical" aggregate="true">
      <entity name="clm_credential">
        <attribute name="clm_credentialid" alias="aggregate1" aggregate="count" />
        <attribute name="clm_sourcesystem" groupby="true" alias="groupby_column" />
        <filter>
          <condition attribute="clm_status" operator="ne" value="300000007" />
        </filter>
        <order alias="groupby_column" descending="false" />
      </entity>
    </fetch>
  </fetchcollection>
  <categorycollection>
    <category>
      <measurecollection>
        <measure alias="aggregate1" />
      </measurecollection>
    </category>
  </categorycollection>
</datadefinition>
"@

$pdBySource = @"
<Chart Palette="BrightPastel">
  <Series>
    <Series ChartType="Column" Font="{0}, 9.5px" LabelForeColor="59, 59, 59" Name="Series1">
          </Series>
  </Series>
  <ChartAreas>
    <ChartArea BorderColor="White" Name="Default">
      <AxisY LineColor="165, 172, 181"><MajorGrid LineColor="239, 242, 246" /><MajorTickMark LineColor="165, 172, 181" /><LabelStyle Font="{0}, 10.5px" ForeColor="59, 59, 59" /></AxisY>
      <AxisX LineColor="165, 172, 181"><MajorGrid LineColor="239, 242, 246" /><MajorTickMark LineColor="165, 172, 181" /><LabelStyle Font="{0}, 10.5px" ForeColor="59, 59, 59" /></AxisX>
    </ChartArea>
  </ChartAreas>
  <Legends>
    <Legend Alignment="Center" LegendStyle="Table" Docking="Right" Font="{0}, 11px" ForeColor="59, 59, 59" Name="Legend1" />
  </Legends>
  <Titles>
    <Title Alignment="TopLeft" Font="{0}, 13px" ForeColor="0, 0, 0" Text="Credentials by Source System" Name="Title1" />
  </Titles>
</Chart>
"@

Upsert-Chart -EntityCode 'clm_credential' -Name 'Credentials by Source System' `
    -Description 'Column chart of credential count per source system.' `
    -DataDescription $ddBySource `
    -PresentationDescription $pdBySource

# ---------- Chart 3: Expiry Buckets (column) ----------
# Buckets: <0=Expired, 0-7=Critical, 8-30=Soon, 31-90=Watch, 91+=OK
# We can't compute buckets in FetchXML aggregation directly. Group by clm_status as a proxy:
# Status options: Active(300000000), RenewalDue(300000001), InRenewal(300000002), Renewed(300000003),
# Expired(300000004), Suppressed(300000005), Orphaned(300000006), Decommissioned(300000007).
# RenewalDue is auto-bumped at <=30 days, Expired at <0. So this status chart IS a lifecycle funnel.

$ddByLifecycle = @"
<datadefinition>
  <fetchcollection>
    <fetch mapping="logical" aggregate="true">
      <entity name="clm_credential">
        <attribute name="clm_credentialid" alias="aggregate1" aggregate="count" />
        <attribute name="clm_credentialtype" groupby="true" alias="groupby_column" />
        <filter>
          <condition attribute="clm_status" operator="ne" value="300000007" />
        </filter>
      </entity>
    </fetch>
  </fetchcollection>
  <categorycollection>
    <category>
      <measurecollection>
        <measure alias="aggregate1" />
      </measurecollection>
    </category>
  </categorycollection>
</datadefinition>
"@

$pdByLifecycle = @"
<Chart Palette="BrightPastel">
  <Series>
    <Series ChartType="Doughnut" Font="{0}, 9.5px" LabelForeColor="59, 59, 59" CustomProperties="DoughnutRadius=60" Name="Series1">
          </Series>
  </Series>
  <ChartAreas>
    <ChartArea BorderColor="White" Name="Default">
      <AxisY LineColor="165, 172, 181"><MajorGrid LineColor="239, 242, 246" /></AxisY>
      <AxisX LineColor="165, 172, 181"><MajorGrid LineColor="239, 242, 246" /></AxisX>
    </ChartArea>
  </ChartAreas>
  <Legends>
    <Legend Alignment="Center" LegendStyle="Table" Docking="Right" Font="{0}, 11px" ForeColor="59, 59, 59" Name="Legend1" />
  </Legends>
  <Titles>
    <Title Alignment="TopLeft" Font="{0}, 13px" ForeColor="0, 0, 0" Text="Credentials by Type" Name="Title1" />
  </Titles>
</Chart>
"@

Upsert-Chart -EntityCode 'clm_credential' -Name 'Credentials by Type' `
    -Description 'Doughnut chart breaking down credentials by clm_credentialtype.' `
    -DataDescription $ddByLifecycle `
    -PresentationDescription $pdByLifecycle

# ---------- Chart 4: Renewal Events by Action last 30 days (column) ----------

$ddEventsByAction = @"
<datadefinition>
  <fetchcollection>
    <fetch mapping="logical" aggregate="true">
      <entity name="clm_renewalevent">
        <attribute name="clm_renewaleventid" alias="aggregate1" aggregate="count" />
        <attribute name="clm_action" groupby="true" alias="groupby_column" />
        <filter>
          <condition attribute="clm_occurredon" operator="last-x-days" value="30" />
        </filter>
      </entity>
    </fetch>
  </fetchcollection>
  <categorycollection>
    <category>
      <measurecollection>
        <measure alias="aggregate1" />
      </measurecollection>
    </category>
  </categorycollection>
</datadefinition>
"@

$pdEventsByAction = @"
<Chart Palette="BrightPastel">
  <Series>
    <Series ChartType="Bar" Font="{0}, 9.5px" LabelForeColor="59, 59, 59" Name="Series1">
          </Series>
  </Series>
  <ChartAreas>
    <ChartArea BorderColor="White" Name="Default">
      <AxisY LineColor="165, 172, 181"><MajorGrid LineColor="239, 242, 246" /></AxisY>
      <AxisX LineColor="165, 172, 181"><MajorGrid LineColor="239, 242, 246" /></AxisX>
    </ChartArea>
  </ChartAreas>
  <Legends>
    <Legend Alignment="Center" LegendStyle="Table" Docking="Right" Font="{0}, 11px" ForeColor="59, 59, 59" Name="Legend1" />
  </Legends>
  <Titles>
    <Title Alignment="TopLeft" Font="{0}, 13px" ForeColor="0, 0, 0" Text="Events by Action (last 30 days)" Name="Title1" />
  </Titles>
</Chart>
"@

Upsert-Chart -EntityCode 'clm_renewalevent' -Name 'Events by Action (30d)' `
    -Description 'Bar chart of renewal-event volume by action type over the last 30 days.' `
    -DataDescription $ddEventsByAction `
    -PresentationDescription $pdEventsByAction

Write-Host ""
Write-Host "Done. Charts visible from the table grid's chart pane (Show chart)." -ForegroundColor Cyan
Write-Host "Next: run Add-CLMAppDashboard.ps1 to create a dashboard that embeds them." -ForegroundColor Cyan
