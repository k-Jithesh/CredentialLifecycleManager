<#
.SYNOPSIS
    Enumerate every Power Pages portal in the tenant via the admin-center
    internal API, fetch SSL certificates per portal, dedupe by thumbprint,
    and upsert each cert into Dataverse as a clm_credential.

.DESCRIPTION
    Two tokens, both delegated user (no app-only support):

      1. Admin-center token - audience https://portal-infra.dynamics.com.
         Acquired one of two ways:
           a) -Interactive switch (recommended): script signs you in via
              Az.Accounts and grabs the token. No browser DevTools needed.
           b) -AdminCenterToken 'eyJ...' parameter: paste a JWT captured
              from the admin-center web UI (DevTools -> Network -> any
              GetCertificatesByPortal request -> Authorization header).
              Tokens expire ~60 min.

      2. Dataverse token - audience https://<DataverseHost>. Acquired via
         Az.Accounts (same Connect-AzAccount session as #1 when -Interactive).
         Used to upsert rows into clm_credential.

    Tenant id is read from the admin-center token's 'tid' claim - no extra
    parameter needed.

    *** UNDOCUMENTED BACKEND API ***
    The portalsitewide-{region}.portal-infra.dynamics.com endpoints used
    here are the same ones the Power Platform admin-center web UI calls.
    They are NOT publicly documented, NOT covered by Microsoft SLA, and
    may change or disappear without notice. Microsoft has not (as of
    writing) enabled service-principal / client-credentials auth on
    these endpoints - delegated user auth with the Power Platform
    Administrator Entra role is the only known working combination.

    Endpoints called:
      GET https://portalsitewide-{region}.portal-infra.dynamics.com
          /api/v1/powerPortal/ListPortals
      GET https://portalsitewide-{region}.portal-infra.dynamics.com
          /api/v1/admincenter/Certificate/GetCertificatesByPortal
          ?tenantId={tid}&portalId={pid}&certType=SSL

    If these stop working, fall back to Seed-CLMPortalCerts.ps1 (CSV).

.PARAMETER Interactive
    Acquire the admin-center token interactively via Az.Accounts. Prompts
    Connect-AzAccount if not already signed in, then calls Get-AzAccessToken
    for the portal-infra.dynamics.com resource. Mutually exclusive with
    -AdminCenterToken.

.PARAMETER AdminCenterToken
    Pre-captured JWT (without 'Bearer ' prefix). Use when you cannot run
    Az.Accounts (locked-down host, automation runbook with stored token,
    etc.). Mutually exclusive with -Interactive.

.PARAMETER TenantId
    Optional Entra tenant id. Only needed with -Interactive to disambiguate
    when the user has access to multiple tenants. Ignored otherwise (the
    tenant id is read from the admin-center token's 'tid' claim).

.PARAMETER DataverseHost
    Dataverse hostname for the CLM environment, e.g.
    'org12345678.crm.dynamics.com'. Required.

.PARAMETER HostRegion
    Region cluster for portalsitewide-{region}.portal-infra.dynamics.com.
    Default 'oce'. Other observed values: emea, amer, ind, jpn, gbr, fra,
    deu, can. Check the host in the admin-center DevTools traffic if 404.

.PARAMETER PortalIdFilter
    Optional - process only the given portal id (handy for testing).

.PARAMETER IncludeWithoutCustomHostNames
    By default only portals that have at least one entry in CustomHostNames
    are processed (a custom hostname is what requires a BYO SSL cert).
    Use this switch to also include portals with no custom hostnames
    (they only have the default *.powerappsportals.com cert managed by MS).

.PARAMETER DumpResponses
    Save raw per-portal cert API responses to OutDir for debugging.

.PARAMETER ListOnly
    Just dump the ListPortals response - no cert calls, no Dataverse writes.

.PARAMETER DryRun
    Fetch portals + certs, show what WOULD be upserted, but skip Dataverse.

.PARAMETER OutDir
    Directory to write raw JSON dumps (portals + per-portal certs).
    Default: current dir.

.EXAMPLE
    # Recommended: interactive sign-in, no DevTools step
    .\Get-CLMPortalCertsViaAdminApi.ps1 -Interactive `
        -DataverseHost '<DATAVERSE_HOST>'

.EXAMPLE
    # Dry-run with interactive sign-in
    .\Get-CLMPortalCertsViaAdminApi.ps1 -Interactive `
        -DataverseHost '<DATAVERSE_HOST>' -DryRun

.EXAMPLE
    # Fallback: paste a JWT captured from DevTools (when Az.Accounts is unusable)
    .\Get-CLMPortalCertsViaAdminApi.ps1 `
        -AdminCenterToken 'eyJ...' `
        -DataverseHost '<DATAVERSE_HOST>'

.EXAMPLE
    # Target a specific portal + dump raw API responses
    .\Get-CLMPortalCertsViaAdminApi.ps1 -Interactive `
        -DataverseHost '<DATAVERSE_HOST>' `
        -PortalIdFilter '00000000-0000-0000-0000-000000000000' `
        -DryRun -DumpResponses

.NOTES
    Undocumented backend API - see DESCRIPTION for caveats.
    Caller must hold the Power Platform Administrator Entra role.
#>
[CmdletBinding(DefaultParameterSetName='Interactive')]
param(
    [Parameter(ParameterSetName='Interactive', Mandatory)] [switch] $Interactive,
    [Parameter(ParameterSetName='Interactive')]            [string] $TenantId,
    [Parameter(ParameterSetName='Token', Mandatory)]       [string] $AdminCenterToken,

    [Parameter(Mandatory)] [string] $DataverseHost,
    [string] $HostRegion     = 'oce',
    [string] $PortalIdFilter,
    [switch] $IncludeWithoutCustomHostNames,
    [switch] $DumpResponses,
    [switch] $ListOnly,
    [switch] $DryRun,
    [string] $OutDir         = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

# Audience for the undocumented admin-center API
$AdminCenterResource = 'https://portal-infra.dynamics.com'

# --- acquire admin-center token (interactive OR provided) -----------------

function Ensure-AzModule {
    if (-not (Get-Module -ListAvailable Az.Accounts)) {
        throw "Az.Accounts module required. Install with: Install-Module Az.Accounts -Scope CurrentUser"
    }
    Import-Module Az.Accounts -ErrorAction Stop
}

if ($PSCmdlet.ParameterSetName -eq 'Interactive') {
    Ensure-AzModule
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx -or ($TenantId -and $ctx.Tenant.Id -ne $TenantId)) {
        Write-Host "Connect-AzAccount (interactive)..." -ForegroundColor Yellow
        if ($TenantId) { Connect-AzAccount -TenantId $TenantId -ErrorAction Stop | Out-Null }
        else           { Connect-AzAccount -ErrorAction Stop | Out-Null }
    }
    Write-Host "Acquiring admin-center token (resource=$AdminCenterResource)..." -ForegroundColor DarkGray
    try {
        $tk = Get-AzAccessToken -ResourceUrl $AdminCenterResource -ErrorAction Stop
        $AdminCenterToken = $tk.Token
    } catch {
        throw "Failed to acquire token for $AdminCenterResource. Your user may lack the Power Platform Administrator role, or the audience may have changed. Original error: $($_.Exception.Message)"
    }
} else {
    # Token mode - strip accidental 'Bearer ' prefix
    if ($AdminCenterToken -match '^\s*Bearer\s+') {
        $AdminCenterToken = $AdminCenterToken -replace '^\s*Bearer\s+',''
    }
}

# --- helpers ---------------------------------------------------------------

function Decode-JwtPayload([string]$Jwt) {
    $parts = $Jwt.Split('.')
    if ($parts.Count -lt 2) { return $null }
    $p = $parts[1].Replace('-','+').Replace('_','/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    try { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json }
    catch { $null }
}

function Invoke-AdminApi([string]$Url, [string]$Token) {
    $raw = Invoke-RestMethod -Method GET -Uri $Url -Headers @{
        Authorization = "Bearer $Token"
        Accept        = 'application/json'
    } -ErrorAction Stop
    # Many of these endpoints return application/json whose body is a quoted
    # JSON string. Auto-decode that second layer.
    if ($raw -is [string]) {
        $t = $raw.TrimStart()
        if ($t.StartsWith('[') -or $t.StartsWith('{')) {
            try { return ($raw | ConvertFrom-Json) } catch { return $raw }
        }
    }
    $raw
}

function Get-Field {
    # Case-insensitive first-match property accessor for varying API casing.
    param([object]$Obj, [string[]]$Names)
    if (-not $Obj) { return $null }
    foreach ($n in $Names) {
        $p = $Obj.PSObject.Properties | Where-Object { $_.Name -ieq $n } | Select-Object -First 1
        if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { return $p.Value }
    }
    $null
}

function Compute-Status([datetime]$Expiry) {
    # clm_credentialstatus integer values:
    #   300000000 Active, 300000001 RenewalDue, 300000004 Expired
    $days = ($Expiry - [DateTime]::UtcNow).TotalDays
    if ($days -lt 0)   { return 300000004 }   # Expired
    if ($days -lt 30)  { return 300000001 }   # RenewalDue
    300000000                                 # Active
}

function Get-PortalHostNames($Portal) {
    # Return an array of custom hostnames found on the portal, or @().
    # Handles many shapes the admin API uses across versions/regions.
    $candidates = @(
        'CustomHostNames','customHostNames','CustomHostnames','customHostnames',
        'CustomDomainNames','customDomainNames','CustomDomains','customDomains',
        'AlternateHostnames','alternateHostnames','AlternateHostNames','alternateHostNames',
        'Hostnames','hostnames','HostNames','hostNames',
        'CustomHosts','customHosts'
    )
    foreach ($n in $candidates) {
        $prop = $Portal.PSObject.Properties | Where-Object { $_.Name -ieq $n } | Select-Object -First 1
        if (-not $prop) { continue }
        $v = $prop.Value
        if ($null -eq $v) { continue }
        if ($v -is [System.Array]) {
            $arr = @($v | Where-Object { $_ -and "$_".Trim().Length -gt 0 })
            if ($arr.Count -gt 0) { return $arr }
        } elseif ($v -is [string]) {
            $s = $v.Trim()
            if ($s.Length -gt 0) {
                return @($s -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
        } elseif ($v.PSObject.Properties.Name -contains 'Names') {
            $arr = @($v.Names | Where-Object { $_ -and "$_".Trim().Length -gt 0 })
            if ($arr.Count -gt 0) { return $arr }
        }
    }
    @()
}

function Has-CustomHostNames($Portal) {
    return ((Get-PortalHostNames $Portal).Count -gt 0)
}

# --- decode admin token + extract tenant id --------------------------------

$claims = Decode-JwtPayload $AdminCenterToken
if (-not $claims) { throw 'Could not decode AdminCenterToken JWT.' }

$tenantId = $claims.tid
if (-not $tenantId) { throw "JWT has no 'tid' claim - is this an Entra-issued token?" }

$expUtc = [DateTimeOffset]::FromUnixTimeSeconds([long]$claims.exp).UtcDateTime
$expMin = [int]($expUtc - [DateTime]::UtcNow).TotalMinutes
Write-Host "`n=== Admin-center token ===" -ForegroundColor Cyan
Write-Host ("  aud      : {0}" -f $claims.aud)
Write-Host ("  tid      : {0}" -f $tenantId)
Write-Host ("  upn/oid  : {0} / {1}" -f $claims.upn, $claims.oid)
Write-Host ("  expires  : {0:u}  ({1} min from now)" -f $expUtc, $expMin)
if ($expMin -lt 5) { Write-Warning "Token expires in $expMin min - capture a fresh one." }

$BaseUrl = "https://portalsitewide-$HostRegion.portal-infra.dynamics.com"

# --- 1. List portals -------------------------------------------------------

Write-Host "`n=== Listing portals ===" -ForegroundColor Cyan
$listUrl = "$BaseUrl/api/v1/powerPortal/ListPortals"
Write-Host "GET $listUrl" -ForegroundColor DarkGray
$portalsRaw = Invoke-AdminApi $listUrl $AdminCenterToken

# Some admin-center endpoints return a JSON STRING containing escaped JSON.
# Detect and double-decode.
if ($portalsRaw -is [string]) {
    $trim = $portalsRaw.TrimStart()
    if ($trim.StartsWith('[') -or $trim.StartsWith('{')) {
        Write-Host "  (double-encoded JSON detected - decoding inner payload)" -ForegroundColor DarkGray
        $portalsRaw = $portalsRaw | ConvertFrom-Json
    }
}

# response could be many shapes - normalise
$portals = $null
if ($portalsRaw -is [System.Array]) {
    $portals = $portalsRaw
} else {
    # Look for common collection-property names, case-insensitive
    foreach ($cn in 'value','Value','portals','Portals','items','Items','results','Results','data','Data') {
        $prop = $portalsRaw.PSObject.Properties | Where-Object { $_.Name -ieq $cn } | Select-Object -First 1
        if ($prop -and $prop.Value) {
            $portals = $prop.Value
            Write-Host ("  envelope key: '$($prop.Name)'") -ForegroundColor DarkGray
            break
        }
    }
    if (-not $portals) {
        # Heuristic: pick the first array-valued top-level property
        $arrayProp = $portalsRaw.PSObject.Properties |
            Where-Object { $_.Value -is [System.Array] } | Select-Object -First 1
        if ($arrayProp) {
            $portals = $arrayProp.Value
            Write-Host ("  envelope key (auto): '$($arrayProp.Name)'") -ForegroundColor DarkGray
        }
    }
    if (-not $portals) {
        Write-Warning "Could not find portal array in response. Top-level keys present:"
        $portalsRaw.PSObject.Properties | ForEach-Object {
            $t = if ($null -eq $_.Value) { '<null>' }
                 elseif ($_.Value -is [System.Array]) { "array[$($_.Value.Count)]" }
                 else { $_.Value.GetType().Name }
            Write-Host ("    {0,-30} : {1}" -f $_.Name, $t)
        }
        $portals = @($portalsRaw)  # fallback - will likely show as one bogus portal
    }
}
if ($portals -isnot [System.Array]) { $portals = @($portals) }

$portalDump = Join-Path $OutDir 'portals-raw.json'
($portalsRaw | ConvertTo-Json -Depth 10) | Set-Content $portalDump -Encoding UTF8
Write-Host ("  found {0} portals (raw dump -> {1})" -f $portals.Count, $portalDump)

if ($ListOnly) {
    Write-Host "`n--- All portal names + detected hostnames ---" -ForegroundColor Yellow
    foreach ($p in $portals) {
        $n  = Get-Field $p 'Name','DisplayName','PortalName','displayName','name'
        $hs = Get-PortalHostNames $p
        Write-Host ("  {0,-40} hosts=[{1}]" -f $n, ($hs -join ','))
    }
    Write-Host "`n--- First portal full JSON (so we can confirm property names) ---" -ForegroundColor Yellow
    $portals[0] | ConvertTo-Json -Depth 6
    return
}

# --- 1b. Filter to portals with custom hostnames unless caller opts out ----

$totalCount = $portals.Count

# Diagnostic table: show each portal's detected hostnames so we can see
# exactly what the filter is comparing.
Write-Host "`n--- Portal hostname diagnostic ---" -ForegroundColor Cyan
$diag = foreach ($p in $portals) {
    $n  = Get-Field $p 'Name','DisplayName','PortalName','displayName','name'
    $hs = Get-PortalHostNames $p
    [pscustomobject]@{
        PortalName    = $n
        HostnameCount = $hs.Count
        Hostnames     = if ($hs.Count) { $hs -join ',' } else { '<none>' }
    }
}
$diag | Format-Table -AutoSize

if (-not $IncludeWithoutCustomHostNames) {
    $portals = $portals | Where-Object { Has-CustomHostNames $_ }
    $skipped = $totalCount - $portals.Count
    Write-Host ("  filtered: keeping {0} portal(s) with hostnames, skipped {1} without" -f `
        $portals.Count, $skipped) -ForegroundColor Yellow
} else {
    Write-Host ("  -IncludeWithoutCustomHostNames: processing all {0} portals" -f $totalCount) -ForegroundColor Yellow
}

if ($portals.Count -eq 0) {
    Write-Host "No portals to process. Exiting." -ForegroundColor Yellow
    return
}

# --- 2. Iterate, fetch certs, build upsert plan ----------------------------

$plan = New-Object System.Collections.Generic.List[object]

foreach ($p in $portals) {
    $portalId     = Get-Field $p 'PortalId','Id','portalId','id','SiteId','siteId'
    $pname   = Get-Field $p 'Name','DisplayName','PortalName','displayName','name'
    $envId   = Get-Field $p 'EnvironmentId','environmentId','EnvId'
    $hostsArr= Get-PortalHostNames $p
    $hostStr = $hostsArr -join ','
    if (-not $portalId) {
        Write-Warning ("  skipping - no portal id found on row: {0}" -f ($p | ConvertTo-Json -Compress -Depth 3))
        continue
    }
    if ($PortalIdFilter -and $portalId -ne $PortalIdFilter) { continue }

    Write-Host ("`n-- Portal: {0}  ({1})" -f $pname, $portalId) -ForegroundColor Cyan
    if ($hostStr) { Write-Host ("   hosts : {0}" -f $hostStr) -ForegroundColor DarkGray }

    foreach ($ct in @('SSL','CustomDomain')) {
        $cUrl = "$BaseUrl/api/v1/admincenter/Certificate/GetCertificatesByPortal" +
                "?tenantId=$tenantId&portalId=$portalId&certType=$ct"
        try {
            $certs = Invoke-AdminApi $cUrl $AdminCenterToken
        } catch {
            $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($code -in 404,400) {
                Write-Host ("    {0}: no certs ({1})" -f $ct, $code) -ForegroundColor DarkGray
                continue
            }
            Write-Warning ("    {0}: failed - {1}" -f $ct, $_.Exception.Message)
            continue
        }
        $certArr = if ($certs -is [System.Array]) { $certs } else { @($certs) }

        if ($DumpResponses) {
            $safeName = ($pname -replace '[^a-zA-Z0-9]','_')
            $dumpPath = Join-Path $OutDir ("certs-raw-{0}-{1}-{2}.json" -f $safeName, $portalId, $ct)
            ($certs | ConvertTo-Json -Depth 10) | Set-Content $dumpPath -Encoding UTF8
            Write-Host ("    {0}: dumped raw -> {1}" -f $ct, $dumpPath) -ForegroundColor DarkGray
        }

        if (-not $certArr -or $certArr.Count -eq 0) {
            Write-Host ("    {0}: no certs" -f $ct) -ForegroundColor DarkGray
            continue
        }

        # dedupe by thumbprint (same cert replicated across regions becomes one row)
        $byThumb = $certArr | Where-Object { $_.Thumbprint } | Group-Object Thumbprint
        Write-Host ("    {0}: {1} raw rows -> {2} distinct cert(s)" -f $ct, $certArr.Count, $byThumb.Count)
        foreach ($g in $byThumb) {
            $first = $g.Group | Select-Object -First 1
            Write-Host ("       - thumb={0}  exp={1}  subj={2}  locs=[{3}]" -f `
                $first.Thumbprint, $first.ExpirationDate, $first.SubjectName, `
                (($g.Group.Location | Sort-Object -Unique) -join ',')) -ForegroundColor DarkGray
        }

        foreach ($g in $byThumb) {
            $c     = $g.Group | Select-Object -First 1
            $locs  = ($g.Group.Location | Sort-Object -Unique) -join ','
            $expS  = "$($c.ExpirationDate)"
            $expDt = $null
            if ($expS) {
                try {
                    # ISO 8601 -> always parse as invariant + treat naive ts as UTC
                    $expDt = [DateTime]::Parse(
                        $expS,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor `
                         [System.Globalization.DateTimeStyles]::AdjustToUniversal))
                } catch {
                    Write-Warning ("    couldn't parse ExpirationDate '{0}' for {1}" -f $expS, $c.Thumbprint)
                }
            }
            if (-not $expDt) { continue }   # skip: better than writing a wrong fallback expiry

            $extId    = "pp:custom:{0}:{1}" -f $portalId, $c.Thumbprint
            $primary  = if ($c.SubjectName) { ($c.SubjectName -split ',')[0].Trim() } else { $c.Thumbprint }
            $tShort   = $c.Thumbprint.Substring(0, [Math]::Min(8, $c.Thumbprint.Length))
            # Include thumbprint suffix so multiple certs on same hostname are visually distinct
            $display  = "{0} - {1} ({2})" -f ($pname ?? $portalId), $primary, $tShort
            $notes    = ("Power Pages BYO custom domain SSL cert (discovered via portal admin API). " +
                         "Portal={0} ({1}). Subject={2}. Thumbprint={3}. Locations={4}. CertType={5}. EnvId={6}." `
                         -f $pname, $portalId, $c.SubjectName, $c.Thumbprint, $locs, $ct, $envId)

            $plan.Add([pscustomobject]@{
                clm_externalid       = $extId
                clm_name             = $display
                clm_displayname      = $display
                clm_sourcesystem     = 100000004                                   # Power Pages Site
                clm_credentialtype   = 200000001                                   # Certificate
                clm_status           = (Compute-Status $expDt)                     # int
                clm_expirydate       = $expDt.ToUniversalTime().ToString('o')
                clm_objectid         = $primary
                clm_keyid            = $c.Thumbprint
                clm_environment      = $envId
                clm_lastdiscoveredon = ([DateTime]::UtcNow.ToString('o'))
                clm_notes            = $notes
                clm_ownersource      = 1000000003                                  # Manual
            })
        }
    }
}

Write-Host ("`n=== Upsert plan: {0} certs ===" -f $plan.Count) -ForegroundColor Cyan
$plan | Format-Table clm_name, clm_keyid, clm_expirydate, clm_status -AutoSize

$planDump = Join-Path $OutDir 'cert-upsert-plan.json'
($plan | ConvertTo-Json -Depth 6) | Set-Content $planDump -Encoding UTF8
Write-Host "plan dumped -> $planDump"

if ($DryRun) { Write-Host "`n[DryRun] skipping Dataverse writes." -ForegroundColor Yellow; return }
if ($plan.Count -eq 0) { Write-Host "Nothing to upsert."; return }

# --- 3. Dataverse upsert ---------------------------------------------------

Write-Host "`n=== Dataverse upsert ===" -ForegroundColor Cyan
Ensure-AzModule
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Write-Host "  Connect-AzAccount (interactive)..." -ForegroundColor Yellow
    Connect-AzAccount -TenantId $tenantId -ErrorAction Stop | Out-Null
}
$dvResource = "https://$DataverseHost"
$dvTokenObj = Get-AzAccessToken -ResourceUrl $dvResource -ErrorAction Stop
$dvToken    = $dvTokenObj.Token
$dvBase = "$dvResource/api/data/v9.2"
$dvHeaders = @{
    Authorization      = "Bearer $dvToken"
    Accept             = 'application/json'
    'OData-MaxVersion' = '4.0'
    'OData-Version'    = '4.0'
    'Content-Type'     = 'application/json'
}
$dvHeadersPatch = $dvHeaders.Clone()
$dvHeadersPatch['If-Match'] = '*'   # required on PATCH to update existing
$entity = 'clm_credentials'

$created = 0; $updated = 0; $failed = 0
foreach ($row in $plan) {
    $extId  = $row.clm_externalid
    $extEsc = $extId -replace "'","''"

    # Look up existing by clm_externalid
    $q = "$dvBase/$entity`?`$select=clm_credentialid&`$filter=clm_externalid eq '$extEsc'"
    try {
        $existing = Invoke-RestMethod -Method GET -Uri $q -Headers $dvHeaders -ErrorAction Stop
    } catch {
        Write-Warning ("  lookup failed for {0}: {1}" -f $extId, $_.Exception.Message)
        $failed++; continue
    }

    # build payload (omit nulls + clm_externalid for PATCH; it's the alt key)
    $payload = @{}
    foreach ($prop in $row.PSObject.Properties) {
        if ($prop.Name -eq 'clm_externalid') { continue }   # set only on create
        if ($null -ne $prop.Value -and "$($prop.Value)" -ne '') { $payload[$prop.Name] = $prop.Value }
    }

    try {
        if ($existing.value -and $existing.value.Count -gt 0) {
            $id  = $existing.value[0].clm_credentialid
            $url = "$dvBase/$entity($id)"
            $body = $payload | ConvertTo-Json -Depth 4
            Invoke-RestMethod -Method PATCH -Uri $url -Headers $dvHeadersPatch -Body $body | Out-Null
            Write-Host ("  updated: {0}" -f $extId) -ForegroundColor DarkGreen
            $updated++
        } else {
            $url = "$dvBase/$entity"
            $payload['clm_externalid'] = $extId
            $body = $payload | ConvertTo-Json -Depth 4
            Invoke-RestMethod -Method POST -Uri $url -Headers $dvHeaders -Body $body | Out-Null
            Write-Host ("  created: {0}" -f $extId) -ForegroundColor Green
            $created++
        }
    } catch {
        Write-Warning ("  upsert failed for {0}: {1}" -f $extId, $_.Exception.Message)
        if ($_.ErrorDetails.Message) { Write-Host ("    detail: {0}" -f $_.ErrorDetails.Message) -ForegroundColor DarkYellow }
        $failed++
    }
}

Write-Host ("`n=== Done. created={0} updated={1} failed={2} ===" -f $created, $updated, $failed) -ForegroundColor Cyan
