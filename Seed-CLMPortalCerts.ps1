<#
.SYNOPSIS
    Upserts Power Pages custom domain SSL cert records into clm_credential from a CSV.

.DESCRIPTION
    Replaces the parked BAP-based discovery flow. Ops maintains a CSV of certs (one
    row per BYO SSL cert per Power Pages site). Script reads the CSV, resolves
    owner emails to systemuser ids, then upserts a clm_credential row per cert.

    Idempotent - uses clm_externalid as the upsert key. Re-running the script
    after editing the CSV will UPDATE existing rows (e.g. when a cert is renewed,
    update the expiry date in the CSV and re-run).

.PARAMETER EnvironmentUrl
    CLM Dataverse env URL, e.g. https://<DATAVERSE_HOST>

.PARAMETER CsvPath
    Path to the cert CSV. See sample CSV at the end of this header.

.PARAMETER WhatIf
    Preview what would be created/updated without making changes.

.EXAMPLE
    pwsh ./Seed-CLMPortalCerts.ps1 -EnvironmentUrl https://<DATAVERSE_HOST> -CsvPath ./portal_certs.csv -WhatIf
    pwsh ./Seed-CLMPortalCerts.ps1 -EnvironmentUrl https://<DATAVERSE_HOST> -CsvPath ./portal_certs.csv

.NOTES
    Sample CSV format (UTF-8, header row required):

    SiteName,HostName,Thumbprint,ExpiryDate,OwnerEmail,Environment,Notes
    Contact Portal,pp-contoso.example.com,71B279A778BC0FB04949966D06...,2026-11-29T23:59:59Z,jane.smith@example.com,prod,"Customer portal SSL"
    Permit Portal,pp-permit.example.com,82C390B889CD1FC15A5BAA77E17...,2027-03-15T23:59:59Z,it-platform@example.com,prod,"Customer permit portal SSL"

    Columns:
      SiteName     - Required. Power Pages site display name (used in clm_displayname)
      HostName     - Required. Custom domain (used in clm_displayname + externalid)
      Thumbprint   - Required. Cert thumbprint (used in clm_externalid + clm_keyid)
      ExpiryDate   - Required. ISO 8601 UTC datetime (e.g. 2026-11-29T23:59:59Z)
      OwnerEmail   - Optional. If set, resolves to a Dataverse systemuser and assigns Owner User. Warns if not found.
      Environment  - Optional. Free text label (e.g. prod, uat, customer-name).
      Notes        - Optional. Free text. Appended to the auto-generated note.

    Requires PowerShell 7+, Az.Accounts module (auto-installed). Caller needs a
    security role with create/update on clm_credential in the CLM env.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentUrl,
    [Parameter(Mandatory)] [string] $CsvPath,
    [string] $TenantId,
    [string] $AccountId = '<OPS_EMAIL>',
    [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'

# Validate CSV
if (-not (Test-Path $CsvPath)) {
    throw "CSV not found: $CsvPath"
}

$rows = Import-Csv -Path $CsvPath
if (-not $rows -or $rows.Count -eq 0) {
    throw "CSV has no data rows: $CsvPath"
}

# Validate required columns on first row
$required = @('SiteName','HostName','Thumbprint','ExpiryDate')
$missingCols = $required | Where-Object { $rows[0].PSObject.Properties.Name -notcontains $_ }
if ($missingCols) {
    throw "CSV missing required columns: $($missingCols -join ', '). Header row must include SiteName,HostName,Thumbprint,ExpiryDate (OwnerEmail,Environment,Notes optional)."
}

# --- Auth ---
if (-not (Get-Module -ListAvailable Az.Accounts)) {
    Write-Host 'Installing Az.Accounts...' -ForegroundColor Yellow
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
}
$apiBase = "$resource/api/data/v9.2"

function Invoke-Dv {
    param([string]$Method, [string]$Path, [object]$Body, [hashtable]$ExtraHeaders)
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
    $key = $Email.Trim().ToLower()
    if ($userCache.ContainsKey($key)) { return $userCache[$key] }
    $esc = $key.Replace("'", "''")
    $r = Invoke-Dv -Method GET -Path "systemusers?`$filter=internalemailaddress eq '$esc' or domainname eq '$esc'&`$select=systemuserid,fullname&`$top=1"
    if (-not $r.value -or $r.value.Count -eq 0) {
        Write-Warning "    ! User not found: $Email"
        $userCache[$key] = $null
        return $null
    }
    $userCache[$key] = [string]$r.value[0].systemuserid
    return $userCache[$key]
}

function Get-CredentialIdByExternalId {
    param([string]$ExternalId)
    $esc = $ExternalId.Replace("'", "''")
    $r = Invoke-Dv -Method GET -Path "clm_credentials?`$filter=clm_externalid eq '$esc'&`$select=clm_credentialid&`$top=1"
    if ($r.value -and $r.value.Count -gt 0) { return [string]$r.value[0].clm_credentialid }
    return $null
}

# --- Apply ---
Write-Host ""
Write-Host "Seeding portal cert records into $resource" -ForegroundColor Cyan
Write-Host "CSV rows: $($rows.Count)" -ForegroundColor Cyan
if ($WhatIf) { Write-Host "[WhatIf mode - no changes will be made]" -ForegroundColor Yellow }
Write-Host ""

$created = 0; $updated = 0; $skipped = 0; $warned = 0

foreach ($row in $rows) {
    $siteName   = ($row.SiteName   -as [string]).Trim()
    $hostName   = ($row.HostName   -as [string]).Trim()
    $thumbprint = ($row.Thumbprint -as [string]).Trim().Replace(' ', '').ToUpper()
    $expiryRaw  = ($row.ExpiryDate -as [string]).Trim()
    $ownerEmail = if ($row.PSObject.Properties.Name -contains 'OwnerEmail') { ($row.OwnerEmail -as [string]).Trim() } else { '' }
    $envLabel   = if ($row.PSObject.Properties.Name -contains 'Environment') { ($row.Environment -as [string]).Trim() } else { '' }
    $userNotes  = if ($row.PSObject.Properties.Name -contains 'Notes') { ($row.Notes -as [string]).Trim() } else { '' }

    if (-not $siteName -or -not $hostName -or -not $thumbprint -or -not $expiryRaw) {
        Write-Warning "Skipping row with missing required field: $($row | ConvertTo-Json -Compress)"
        $warned++; continue
    }

    # Parse + normalize expiry
    try {
        $expiry = [DateTime]::Parse($expiryRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal).ToString('o')
    } catch {
        Write-Warning "Skipping row - invalid ExpiryDate '$expiryRaw': $($_.Exception.Message)"
        $warned++; continue
    }

    $externalId = "pp:manual:$hostName`:$thumbprint"
    $displayName = "$siteName - $hostName"

    Write-Host (" - {0,-25} {1,-32} (exp {2})" -f $hostName, $thumbprint.Substring(0, [Math]::Min(28, $thumbprint.Length)), $expiry.Substring(0,10)) -ForegroundColor White

    $autoNote = "Power Pages BYO custom domain SSL cert (manually entered via Seed-CLMPortalCerts.ps1). Host=$hostName. Thumbprint=$thumbprint."
    $combinedNotes = if ($userNotes) { "$autoNote $userNotes" } else { $autoNote }

    $body = [ordered]@{
        clm_name           = $displayName
        clm_displayname    = $displayName
        clm_sourcesystem   = 100000004   # Power Pages Site
        clm_credentialtype = 200000001   # Certificate
        clm_status         = 300000000   # Active
        clm_expirydate     = $expiry
        clm_objectid       = $hostName
        clm_keyid          = $thumbprint
        clm_environment    = $envLabel
        clm_lastdiscoveredon = (Get-Date).ToUniversalTime().ToString('o')
        clm_notes          = $combinedNotes
        clm_ownersource    = 1000000003  # Manual
    }

    # Owner resolution
    if ($ownerEmail) {
        $ownerId = Resolve-UserId -Email $ownerEmail
        if ($ownerId) {
            $body.'clm_owneruser@odata.bind' = "/systemusers($ownerId)"
            # Lock so OwnerResolver doesn't auto-reassign by rules
            $body.clm_ownerlocked = $true
        }
    }

    if ($WhatIf) {
        Write-Host "   [WhatIf] body:" -ForegroundColor Yellow
        $body | Format-Table | Out-String | Write-Host
        continue
    }

    $existingId = Get-CredentialIdByExternalId -ExternalId $externalId
    try {
        if ($existingId) {
            Invoke-Dv -Method PATCH -Path "clm_credentials($existingId)" -Body $body | Out-Null
            Write-Host "   updated existing ($existingId)" -ForegroundColor DarkGreen
            $updated++
        } else {
            # Need to set clm_externalid on create only
            $bodyForCreate = $body.Clone()
            $bodyForCreate.clm_externalid = $externalId
            $r = Invoke-Dv -Method POST -Path "clm_credentials" -Body $bodyForCreate -ExtraHeaders @{ 'Prefer' = 'return=representation' }
            Write-Host ("   created new ({0})" -f $r.clm_credentialid) -ForegroundColor Green
            $created++
        }
    } catch {
        Write-Warning "   FAILED: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) { Write-Warning "   $($_.ErrorDetails.Message)" }
        $warned++
    }
}

Write-Host ""
Write-Host ("Done. Created: {0}, updated: {1}, warned: {2}" -f $created, $updated, $warned) -ForegroundColor Cyan
Write-Host "Verify in the Credential Lifecycle app - filter by Source System = Power Pages Site." -ForegroundColor Cyan
