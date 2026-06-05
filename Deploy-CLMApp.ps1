<#
.SYNOPSIS
    Deploys the Credential Lifecycle Manager (CLM) Model-Driven App via the Dataverse Web API.

.DESCRIPTION
    Idempotent — safe to re-run. Reads app/app_manifest.json + sitemap/view XML files
    and creates/updates:
      * SavedQuery (system views) for the entities listed in the manifest
      * SiteMap with the manifest's sitemap XML
      * AppModule (Model-Driven App shell) bound to the sitemap
      * AppModuleComponent rows registering entities + views + sitemap with the app
      * Adds the app to the CredentialLifecycleManager solution
      * Publishes customizations

    Mirrors the auth + Invoke-Dv pattern used by Deploy-CLMSchema.ps1 so it works in
    the same Dev/Test/Prod environments without extra setup.

.PARAMETER EnvironmentUrl
    e.g. https://contoso.crm6.dynamics.com

.PARAMETER ManifestPath
    Path to app/app_manifest.json (defaults to alongside this script).

.EXAMPLE
    pwsh ./Deploy-CLMApp.ps1 -EnvironmentUrl https://contoso.crm6.dynamics.com

.NOTES
    Requires PowerShell 7+, Az.Accounts, and System Customizer / System Administrator
    on the target environment.
#>

[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [Parameter()] [string] $EnvironmentUrl = 'https://<DATAVERSE_HOST>',
    [string] $ManifestPath = (Join-Path $PSScriptRoot 'app/app_manifest.json'),

    [Parameter(ParameterSetName = 'Interactive')]
    [Parameter(ParameterSetName = 'ServicePrincipal', Mandatory)]
    [Parameter(ParameterSetName = 'ServicePrincipalCert', Mandatory)]
    [string] $TenantId,

    [Parameter(ParameterSetName = 'Interactive')]
    [string] $AccountId,

    [Parameter(ParameterSetName = 'Interactive')]
    [switch] $UseDeviceCode,

    [Parameter(ParameterSetName = 'ServicePrincipal', Mandatory)]
    [Parameter(ParameterSetName = 'ServicePrincipalCert', Mandatory)]
    [switch] $ServicePrincipal,

    [Parameter(ParameterSetName = 'ServicePrincipal', Mandatory)]
    [Parameter(ParameterSetName = 'ServicePrincipalCert', Mandatory)]
    [string] $ClientId,

    [Parameter(ParameterSetName = 'ServicePrincipal', Mandatory)]
    [string] $ClientSecret,

    [Parameter(ParameterSetName = 'ServicePrincipalCert', Mandatory)]
    [string] $CertificateThumbprint
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Auth (mirrors Deploy-CLMSchema.ps1)
# -----------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable Az.Accounts)) {
    Write-Host 'Installing Az.Accounts...' -ForegroundColor Yellow
    Install-Module Az.Accounts -Scope CurrentUser -Force -AllowClobber
}
Import-Module Az.Accounts

$resource = $EnvironmentUrl.TrimEnd('/')
$isSp     = $ServicePrincipal.IsPresent

$ctx       = Get-AzContext
$needLogin = $true
if ($ctx -and -not $isSp) {
    if (-not $TenantId -or $ctx.Tenant.Id -eq $TenantId) { $needLogin = $false }
}

if ($needLogin) {
    $connectArgs = @{ ErrorAction = 'Stop' }
    if ($TenantId) { $connectArgs.TenantId = $TenantId }

    if ($isSp) {
        $connectArgs.ServicePrincipal = $true
        $connectArgs.ApplicationId    = $ClientId
        if ($PSCmdlet.ParameterSetName -eq 'ServicePrincipalCert') {
            $connectArgs.CertificateThumbprint = $CertificateThumbprint
        } else {
            $secure = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
            $connectArgs.Credential = [System.Management.Automation.PSCredential]::new($ClientId, $secure)
            $connectArgs.Remove('ApplicationId') | Out-Null
        }
        Write-Host "Signing in as service principal $ClientId to tenant $TenantId..." -ForegroundColor Cyan
        Connect-AzAccount @connectArgs | Out-Null
    }
    else {
        if ($AccountId)     { $connectArgs.AccountId = $AccountId }
        if ($UseDeviceCode) { $connectArgs.UseDeviceAuthentication = $true }
        try {
            Connect-AzAccount @connectArgs | Out-Null
        } catch {
            Write-Warning "Interactive sign-in failed: $($_.Exception.Message)"
            Write-Host 'Retrying with device-code flow...' -ForegroundColor Yellow
            $connectArgs.UseDeviceAuthentication = $true
            Connect-AzAccount @connectArgs | Out-Null
        }
    }
}

$tokenArgs = @{ ResourceUrl = $resource }
if ($TenantId) { $tokenArgs.TenantId = $TenantId }
$token = (Get-AzAccessToken @tokenArgs).Token

$headers  = @{
    Authorization              = "Bearer $token"
    'OData-MaxVersion'         = '4.0'
    'OData-Version'            = '4.0'
    Accept                     = 'application/json'
    'Content-Type'             = 'application/json; charset=utf-8'
}
# NOTE: we intentionally do NOT set 'MSCRM.SolutionUniqueName' on the shared
# header. If we did, every failed POST would still register a solutioncomponent
# pointing at a non-existent record, leaving orphans that block future deploys.
# We add the app to the solution explicitly at the end via AddSolutionComponent.
$apiBase = "$resource/api/data/v9.2"

# -----------------------------------------------------------------------------
# Manifest + helpers
# -----------------------------------------------------------------------------
$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json -Depth 30
$appDir   = Split-Path $ManifestPath -Parent

$script:NotFoundCodes  = @('0x80060888','0x80090020','0x8006088a','0x80060889')
$script:DuplicateCodes = @('duplicate','already exists','0x80045001','0x80060891','0x80060890','0x8004f50c','0x80060835','0x80044150')

function Invoke-Dv {
    param(
        [Parameter(Mandatory)] $Method,
        [Parameter(Mandatory)] $Path,
        $Body,
        [switch] $AllowNotFound,
        [switch] $AllowDuplicate,
        [switch] $ReturnRepresentation
    )
    $uri = if ($Path -match '^https?://') { $Path } else { "$apiBase/$Path" }
    $callHeaders = $headers.Clone()
    if ($ReturnRepresentation) {
        $callHeaders['Prefer'] = 'return=representation'
    }
    $params = @{ Method = $Method; Uri = $uri; Headers = $callHeaders }
    if ($null -ne $Body) {
        $json = ($Body | ConvertTo-Json -Depth 30 -Compress)
        $params.Body = [Text.Encoding]::UTF8.GetBytes($json)
    }
    try {
        return Invoke-RestMethod @params
    } catch {
        $msg    = $_.ErrorDetails.Message
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }

        $isNotFound = ($status -eq 404) -or
                      ($msg -and ($script:NotFoundCodes | Where-Object { $msg -match $_ })) -or
                      ($msg -match 'does not exist|Could not find|was not found')
        if ($isNotFound -and ($Method -eq 'GET' -or $AllowNotFound)) { return $null }

        $isDuplicate = $false
        if ($msg) {
            foreach ($pat in $script:DuplicateCodes) {
                if ($msg -match [regex]::Escape($pat)) { $isDuplicate = $true; break }
            }
        }
        if ($isDuplicate -and ($Method -in @('POST','PATCH','PUT') -or $AllowDuplicate)) {
            Write-Host "  (exists) $Path" -ForegroundColor DarkGray
            return $null
        }

        throw "Dataverse $Method $Path failed [$status]: $msg"
    }
}

function Get-EntityOtc([string]$logicalName) {
    $r = Invoke-Dv GET "EntityDefinitions(LogicalName='$logicalName')?`$select=ObjectTypeCode,MetadataId,PrimaryIdAttribute"
    if (-not $r) { throw "Entity '$logicalName' not found. Ensure schema has been deployed." }
    return $r
}

function Get-LookupNavProperty([string]$referencingEntity, [string]$referencingAttribute) {
    # Returns the OData navigation property name for a lookup column.
    # Needed because @odata.bind uses nav property names, not attribute names.
    $r = Invoke-Dv GET ("RelationshipDefinitions/Microsoft.Dynamics.CRM.ManyToOneRelationshipMetadata?`$filter=ReferencingEntity eq '{0}' and ReferencingAttribute eq '{1}'&`$select=ReferencingEntityNavigationPropertyName" -f $referencingEntity, $referencingAttribute)
    if (-not $r -or -not $r.value -or $r.value.Count -eq 0) {
        throw "No relationship found for $referencingEntity.$referencingAttribute"
    }
    return $r.value[0].ReferencingEntityNavigationPropertyName
}

function Read-XmlFile([string]$relativePath) {
    $full = Join-Path $appDir $relativePath
    if (-not (Test-Path $full)) { throw "File not found: $full" }
    (Get-Content $full -Raw).Trim()
}

# -----------------------------------------------------------------------------
# 1. Saved Queries (system views)
# -----------------------------------------------------------------------------
function Set-SavedQuery($view) {
    Write-Host "View: $($view.uniqueName) ($($view.entity))..." -ForegroundColor Cyan
    $ent = Get-EntityOtc $view.entity

    $fetch  = Read-XmlFile $view.fetchFile
    $layout = (Read-XmlFile $view.layoutFile) -replace 'object="0"', "object=`"$($ent.ObjectTypeCode)`""

    # Look up by name + returnedtypecode. We don't have a savedquery uniquename
    # column, so we use a stable name match. URL-encode the display name because
    # it can contain spaces / apostrophes that break the query string.
    $encName = [uri]::EscapeDataString($view.displayName)
    $existing = Invoke-Dv GET ("savedqueries?`$filter=name eq '{0}' and returnedtypecode eq '{1}'&`$select=savedqueryid" -f $encName, $view.entity)

    $body = @{
        name                = $view.displayName
        description         = $view.description
        returnedtypecode    = $view.entity
        querytype           = [int]$view.queryType
        fetchxml            = $fetch
        layoutxml           = $layout
        iscustomizable      = @{ Value = [bool]$view.isCustomizable; CanBeChanged = $true; ManagedPropertyLogicalName = 'iscustomizable' }
    }
    if ($view.isDefault) { $body.isdefault = $true }

    if ($existing.value.Count -gt 0) {
        $id = $existing.value[0].savedqueryid
        Invoke-Dv PATCH "savedqueries($id)" $body | Out-Null
        Write-Host "  updated $id" -ForegroundColor DarkGreen
        return $id
    }

    $created = Invoke-Dv POST 'savedqueries' $body -ReturnRepresentation
    if ($created -and $created.savedqueryid) {
        Write-Host "  created $($created.savedqueryid)" -ForegroundColor Green
        return $created.savedqueryid
    }
    throw "Failed to create savedquery '$($view.displayName)' for entity '$($view.entity)' — no id returned."
}

# -----------------------------------------------------------------------------
# 2. SiteMap
# -----------------------------------------------------------------------------
function Set-SiteMap {
    $sm = $manifest.siteMap
    Write-Host "SiteMap: $($sm.uniqueName)..." -ForegroundColor Cyan
    $xml = Read-XmlFile $sm.xmlFile

    $encName  = [uri]::EscapeDataString($sm.uniqueName)
    $existing = Invoke-Dv GET ("sitemaps?`$filter=sitemapnameunique eq '{0}'&`$select=sitemapid" -f $encName)

    $body = @{
        sitemapname        = $sm.displayName
        sitemapnameunique  = $sm.uniqueName
        sitemapxml         = $xml
    }

    if ($existing.value.Count -gt 0) {
        $id = $existing.value[0].sitemapid
        Invoke-Dv PATCH "sitemaps($id)" $body | Out-Null
        Write-Host "  updated $id" -ForegroundColor DarkGreen
        return $id
    }

    $created = Invoke-Dv POST 'sitemaps' $body -ReturnRepresentation
    if ($created -and $created.sitemapid) {
        Write-Host "  created $($created.sitemapid)" -ForegroundColor Green
        return $created.sitemapid
    }
    throw "Failed to create sitemap '$($sm.uniqueName)' — no id returned."
}

# -----------------------------------------------------------------------------
# 2b. System Charts (savedqueryvisualization)
# -----------------------------------------------------------------------------
function Set-Chart($chart) {
    Write-Host "Chart: $($chart.uniqueName) ($($chart.entity))..." -ForegroundColor Cyan

    $fetch        = Read-XmlFile $chart.fetchFile
    $presentation = Read-XmlFile $chart.presentationFile

    $encName = [uri]::EscapeDataString($chart.displayName)
    $existing = Invoke-Dv GET ("savedqueryvisualizations?`$filter=name eq '{0}' and primaryentitytypecode eq '{1}'&`$select=savedqueryvisualizationid" -f $encName, $chart.entity)

    $body = @{
        name                  = $chart.displayName
        description           = $chart.description
        primaryentitytypecode = $chart.entity
        datadescription       = $fetch
        presentationdescription = $presentation
        isdefault             = $false
    }

    if ($existing.value.Count -gt 0) {
        $id = $existing.value[0].savedqueryvisualizationid
        Invoke-Dv PATCH "savedqueryvisualizations($id)" $body | Out-Null
        Write-Host "  updated $id" -ForegroundColor DarkGreen
        return $id
    }

    $created = Invoke-Dv POST 'savedqueryvisualizations' $body -ReturnRepresentation
    if ($created -and $created.savedqueryvisualizationid) {
        Write-Host "  created $($created.savedqueryvisualizationid)" -ForegroundColor Green
        return $created.savedqueryvisualizationid
    }
    throw "Failed to create chart '$($chart.displayName)' for entity '$($chart.entity)'."
}

# -----------------------------------------------------------------------------
# 2a. App Icon (web resource)
# -----------------------------------------------------------------------------
function Set-AppIcon {
    $icon = $manifest.appIcon
    if (-not $icon) { return $null }
    Write-Host "Web resource (app icon): $($icon.name)..." -ForegroundColor Cyan

    $iconFull = Join-Path $appDir $icon.file
    if (-not (Test-Path $iconFull)) { throw "Icon file not found: $iconFull" }
    $bytes   = [IO.File]::ReadAllBytes($iconFull)
    $b64     = [Convert]::ToBase64String($bytes)

    $encName  = [uri]::EscapeDataString($icon.name)
    $existing = Invoke-Dv GET ("webresourceset?`$filter=name eq '{0}'&`$select=webresourceid" -f $encName)

    $body = @{
        name            = $icon.name
        displayname     = $icon.displayName
        webresourcetype = [int]$icon.type
        content         = $b64
    }

    if ($existing.value.Count -gt 0) {
        $id = $existing.value[0].webresourceid
        Invoke-Dv PATCH "webresourceset($id)" $body | Out-Null
        Write-Host "  updated $id" -ForegroundColor DarkGreen
        return $id
    }

    $created = Invoke-Dv POST 'webresourceset' $body -ReturnRepresentation
    if (-not ($created -and $created.webresourceid)) {
        throw "Failed to create web resource '$($icon.name)'."
    }
    Write-Host "  created $($created.webresourceid)" -ForegroundColor Green
    return $created.webresourceid
}

# -----------------------------------------------------------------------------
# 3. AppModule
# -----------------------------------------------------------------------------
function Set-AppModule($sitemapId, $iconWebResourceId) {
    $a = $manifest.app
    Write-Host "AppModule: $($a.uniqueName)..." -ForegroundColor Cyan

    $encName  = [uri]::EscapeDataString($a.uniqueName)
    # The script does NOT create the appmodule. Dataverse's appmodule Web API
    # surface is too quirky (security-trim, 0x80050135 opaque errors, ghost
    # solutioncomponents). Create the empty shell once in the maker UI, then
    # this script PATCHes everything else.
    $id = $null
    try {
        $byKey = Invoke-Dv GET "appmodules(uniquename='$encName')?`$select=appmoduleid" -AllowNotFound
        if ($byKey -and $byKey.appmoduleid) { $id = $byKey.appmoduleid }
    } catch { }
    if (-not $id) {
        $existing = Invoke-Dv GET ("appmodules?`$filter=uniquename eq '{0}'&`$select=appmoduleid" -f $encName)
        if ($existing -and $existing.value.Count -gt 0) { $id = $existing.value[0].appmoduleid }
    }
    if (-not $id) {
        throw @"
AppModule '$($a.uniqueName)' not found in $resource.
Create the empty shell in maker UI first:
  1. https://make.powerapps.com -> Apps -> + New app -> Model-driven
  2. Name:        $($a.name)
     Unique name: $($a.uniqueName)
  3. Save (don't worry about adding tables — this script does that).
  4. Re-run Deploy-CLMApp.ps1.
"@
    }

    $body = @{
        name           = $a.name
        description    = $a.description
        clienttype     = [int]$a.clientType
        navigationtype = [int]$a.navigationType
    }
    if ($iconWebResourceId) {
        # appmodule.webresourceid is a plain Guid column (not a navigation property),
        # so set it directly rather than using @odata.bind.
        $body.webresourceid = [string]$iconWebResourceId
    }
    Invoke-Dv PATCH "appmodules($id)" $body | Out-Null
    Write-Host "  patched $id" -ForegroundColor DarkGreen

    # Bind sitemap (PATCH the navigation property)
    $bindBody = @{ 'appmoduleidunique@odata.bind' = "/sitemaps($sitemapId)" }
    # Newer Dataverse uses a dedicated association; use single-valued nav prop:
    $assoc = @{ '@odata.id' = "$apiBase/sitemaps($sitemapId)" }
    try {
        Invoke-Dv PUT "appmodules($id)/appmodule_sitemap/`$ref" $assoc | Out-Null
    } catch {
        Write-Warning "Sitemap bind via appmodule_sitemap/`$ref failed: $($_.Exception.Message). Trying AddAppComponents fallback."
    }

    return $id
}

# -----------------------------------------------------------------------------
# 4. App Components (entities, views, sitemap)
# -----------------------------------------------------------------------------
# componenttype:  1 = Entity, 26 = SavedQuery, 62 = SiteMap, 60 = SystemForm
function Add-AppComponents($appId, [array]$components) {
    if (-not $components -or $components.Count -eq 0) { return }
    Write-Host "Registering $($components.Count) component(s) with app..." -ForegroundColor Cyan
    # Create appmodulecomponent rows directly. componenttype:
    #   1 = Entity, 26 = SavedQuery, 60 = SystemForm, 62 = SiteMap
    foreach ($c in $components) {
        $body = @{
            'appmoduleidunique@odata.bind' = "/appmodules($appId)"
            componenttype                  = [int]$c.componenttype
            objectid                       = [string]$c.objectid
        }
        try {
            Invoke-Dv POST 'appmodulecomponents' $body -AllowDuplicate | Out-Null
            Write-Host "  + type=$($c.componenttype) $($c.objectid)" -ForegroundColor DarkGreen
        } catch {
            Write-Warning "  failed type=$($c.componenttype) $($c.objectid): $($_.Exception.Message)"
        }
    }
    Write-Host "  registered" -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 5. Add the app to the solution
# -----------------------------------------------------------------------------
function Add-AppToSolution($appId) {
    Write-Host "Adding app to solution $($manifest.solution.uniqueName)..." -ForegroundColor Cyan
    $body = @{
        ComponentId        = $appId
        ComponentType      = 80     # AppModule
        SolutionUniqueName = $manifest.solution.uniqueName
        AddRequiredComponents = $false
        DoNotIncludeSubcomponents = $false
        IncludedComponentSettingsValues = $null
    }
    Invoke-Dv POST 'AddSolutionComponent' $body -AllowDuplicate | Out-Null
    Write-Host "  added" -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 6. Publish
# -----------------------------------------------------------------------------
function Publish-All {
    Write-Host "Publishing customizations..." -ForegroundColor Cyan
    Invoke-Dv POST 'PublishAllXml' @{} | Out-Null
    Write-Host "  published" -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
Write-Host "`n=== CLM Model-Driven App deploy ===" -ForegroundColor Magenta
Write-Host "Target : $resource"
Write-Host "App    : $($manifest.app.uniqueName)`n"

# Views
$viewIds = @{}
foreach ($v in $manifest.views) {
    $viewIds[$v.uniqueName] = Set-SavedQuery $v
}

# Charts (system charts via savedqueryvisualization)
$chartIds = @{}
if ($manifest.charts) {
    foreach ($c in $manifest.charts) {
        $chartIds[$c.uniqueName] = Set-Chart $c
    }
}

# Sitemap
$sitemapId = Set-SiteMap

# App icon
$iconId = Set-AppIcon

# App
$appId = Set-AppModule -sitemapId $sitemapId -iconWebResourceId $iconId

# Components: entities + views + sitemap. componenttype: 1=Entity, 26=SavedQuery, 62=SiteMap
$componentRefs = @()
foreach ($c in $manifest.components) {
    if ($c.type -eq 'entity') {
        $ent = Get-EntityOtc $c.logicalName
        $componentRefs += @{ componenttype = 1;  objectid = $ent.MetadataId }
    }
}
foreach ($v in $manifest.views) {
    $componentRefs += @{ componenttype = 26; objectid = $viewIds[$v.uniqueName] }
}
# componenttype 59 = SavedQueryVisualization (system chart)
foreach ($u in $chartIds.Keys) {
    $componentRefs += @{ componenttype = 59; objectid = $chartIds[$u] }
}
$componentRefs += @{ componenttype = 62; objectid = $sitemapId }

Add-AppComponents -appId $appId -components $componentRefs

# Add to solution
Add-AppToSolution -appId $appId

# Publish
Publish-All

Write-Host "`n=== Done ===" -ForegroundColor Magenta
Write-Host "Open the app:" -ForegroundColor Green
Write-Host "  $resource/main.aspx?appid=$appId" -ForegroundColor Yellow
Write-Host ""
